module fundmint::project_registry {
    use sui::object as object;
    use sui::object::UID;
    use sui::tx_context as tx_context;
    use sui::tx_context::{TxContext, sender, epoch};
    use sui::coin as coin;
    use sui::coin::{Coin, value};
    use sui::transfer as transfer;
    use sui::transfer::{public_transfer, public_share_object};
    use sui::event as event;
    use sui::sui::SUI;
    use sui::table as table;
    use sui::table::{Table, keys};
    use sui::dynamic_field as df;
    use std::vector;
    use std::string as string;
    use std::string::String;

    /// Error Codes
    const EProjectNotFound: u64 = 1;
    const EUnauthorized: u64 = 2;
    const EInvalidStatus: u64 = 3;
    const EInvalidFundingAmount: u64 = 4;
    
    /// Vault wallet for platform fees
    const VAULT_WALLET: address = @0xcce6383bfe67b855f93e9d7ebb61296061c4cd15f303af884c3e0088a4f75e46;

    /// Represents the state of a project
    public enum ProjectStatus has copy, drop, store {
        Open,
        Funded,
        Closed,
    }

    /// Core project structure
    public struct Project has key, store {
        id: UID,
        owner: address,
        name: String,
        description: String,
        funding_goal: u64,
        current_funds: u64,
        status: ProjectStatus,
        creation_time: u64,
    }

    /// Project donation record
    public struct ProjectDonation has store {
        donor: address,
        amount: u64,
        timestamp: u64,
    }

    /// Master registry of all projects
    public struct ProjectRegistry has key {
        id: UID,
        project_count: u64,
    }

    /// Events
    public struct ProjectCreated has drop, store {
        project_id: String,
        owner: address,
        funding_goal: u64,
    }

    public struct DonationReceived has drop, store {
        project_id: String,
        donor: address,
        amount: u64,
        fee_amount: u64,
    }

    public struct ProjectClosed has drop, store {
        project_id: String,
        owner: address,
    }

    /// Initialize the registry
    public entry fun create_registry(ctx: &mut TxContext) {
        let registry = ProjectRegistry {
            id: object::new(ctx),
            project_count: 0,
        };
        transfer::public_share_object(registry);
    }

    /// Create a new project
    public entry fun create_project(
        registry: &mut ProjectRegistry,
        project_id: String,
        name: String,
        description: String,
        funding_goal: u64,
        fee_payment: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        // Calculate fee (1%)
        let fee_amount = funding_goal / 100;
        assert!(value(&fee_payment) >= fee_amount, EInvalidFundingAmount);

        // Split out fee
        let fee = coin::split(&mut fee_payment, fee_amount, ctx);
        
        // Send fee to vault wallet
        transfer::public_transfer(fee, VAULT_WALLET);
        
        // Refund any remaining payment
        if (value(&fee_payment) > 0) {
            transfer::public_transfer(fee_payment, sender(ctx));
        } else {
            coin::destroy_zero(fee_payment);
        };

        // Create new project
        let new_project = Project {
            id: object::new(ctx),
            owner: sender(ctx),
            name,
            description,
            funding_goal,
            current_funds: 0,
            status: ProjectStatus::Open,
            creation_time: epoch(ctx),
        };

        // Store project directly
        transfer::public_share_object(new_project);
        
        // Increment project count
        registry.project_count = registry.project_count + 1;

        // Add project ID->donations mapping to registry
        df::add(&mut registry.id, project_id, table::new<address, ProjectDonation>(ctx));

        // Emit event
        event::emit(ProjectCreated {
            project_id,
            owner: sender(ctx),
            funding_goal,
        });
    }

    /// Donate to a project
    public entry fun donate_to_project(
        registry: &mut ProjectRegistry,
        project: &mut Project,
        project_id: String,
        mut payment: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        // Verify project is open
        assert!(project.status == ProjectStatus::Open, EInvalidStatus);
        
        // Get donation amount and calculate fee (1%)
        let amount = value(&payment);
        assert!(amount > 0, EInvalidFundingAmount);
        
        let fee_amount = amount / 100;
        let donation_amount = amount - fee_amount;
        
        // Split out fee
        let fee = coin::split(&mut payment, fee_amount, ctx);
        
        // Send fee to vault wallet
        transfer::public_transfer(fee, VAULT_WALLET);
        
        // Track donation in registry
        let donor = sender(ctx);
        let donations_table = df::borrow_mut<String, Table<address, ProjectDonation>>(&mut registry.id, project_id);
        
        // Add donation record
        if (table::contains(donations_table, donor)) {
            // Update existing donation
            let donation = table::borrow_mut(donations_table, donor);
            donation.amount = donation.amount + donation_amount;
            donation.timestamp = epoch(ctx);
        } else {
            // Create new donation record
            table::add(donations_table, donor, ProjectDonation {
                donor,
                amount: donation_amount,
                timestamp: epoch(ctx),
            });
        };
        
        // Update project funding status
        project.current_funds = project.current_funds + donation_amount;
        
        // Check if funding goal reached
        if (project.current_funds >= project.funding_goal) {
            project.status = ProjectStatus::Funded;
        };
        
        // Transfer donation to project owner
        transfer::public_transfer(payment, project.owner);
        
        // Emit event
        event::emit(DonationReceived {
            project_id,
            donor,
            amount: donation_amount,
            fee_amount,
        });
    }

    /// Close a project
    public entry fun close_project(
        project: &mut Project,
        project_id: String,
        ctx: &mut TxContext
    ) {
        // Verify caller is owner
        assert!(sender(ctx) == project.owner, EUnauthorized);
        
        // Verify project is not already closed
        assert!(project.status != ProjectStatus::Closed, EInvalidStatus);
        
        // Close the project
        project.status = ProjectStatus::Closed;
        
        // Emit event
        event::emit(ProjectClosed {
            project_id,
            owner: project.owner,
        });
    }

    /// Get project funders
    public fun get_project_funders(
        registry: &ProjectRegistry,
        project_id: String
    ): vector<address> {
        // Check if project exists
        if (!df::exists_(&registry.id, project_id)) {
            return vector::empty<address>()
        };
        
        // Get donations table
        let donations = df::borrow<String, Table<address, ProjectDonation>>(&registry.id, project_id);
        
        // Return all donor addresses
        table::keys(donations)
    }

    /// Get project donation amount
    public fun get_project_donation(
        registry: &ProjectRegistry,
        project_id: String,
        donor: address
    ): u64 {
        // Check if project exists
        if (!df::exists_(&registry.id, project_id)) {
            return 0
        };
        
        // Get donations table
        let donations = df::borrow<String, Table<address, ProjectDonation>>(&registry.id, project_id);
        
        // Check if donor has donated
        if (!table::contains(donations, donor)) {
            return 0
        };
        
        // Return donation amount
        let donation = table::borrow(donations, donor);
        donation.amount
    }
}