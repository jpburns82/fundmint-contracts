module fundmint::fundmint {
    use sui::object as object;
    use sui::object::UID;
    use sui::tx_context as tx_context;
    use sui::tx_context::{TxContext, sender, epoch};
    use sui::transfer as transfer;
    use sui::transfer::{public_transfer, public_share_object};
    use sui::coin as coin;
    use sui::coin::{Coin, value, split, destroy_zero};
    use sui::sui::SUI;
    use sui::table as table;
    use sui::table::Table;
    use sui::vec_map as vec_map;
    use sui::vec_map::{VecMap, empty, contains, get_mut, insert, keys, get};
    use sui::event as event;
    use std::string as string;
    use std::string::String;
    use std::vector;

    /// Error Codes
    const EProjectNotFound: u64 = 1;
    const EProjectAlreadyExists: u64 = 2;
    const EDeadlinePassed: u64 = 3;
    const EGoalMet: u64 = 4;
    const ENotCreator: u64 = 5;
    const EInsufficientFunds: u64 = 6;
    const EProjectStillActive: u64 = 7;

    /// Fee Constants
    const CREATION_FEE_PERCENT: u64 = 1;
    const DONATION_FEE_PERCENT: u64 = 1;
    
    /// Vault wallet for platform fees
    const VAULT_WALLET: address = @0xcce6383bfe67b855f93e9d7ebb61296061c4cd15f303af884c3e0088a4f75e46;

    /// Core Structures
    public struct ProjectRegistry has key {
        id: UID,
        projects: Table<String, Project>,
        project_donations: Table<String, VecMap<address, u64>>,
    }

    public struct Project has store {
        id: String,
        title: String,
        description: String,
        image_url: String,
        creator: address,
        goal: u64,
        raised: u64,
        deadline: u64,
        active: bool,
    }

    /// Events
    public struct ProjectCreated has drop, store {
        project_id: String,
        creator: address,
        goal: u64,
        deadline: u64,
    }

    public struct DonationReceived has drop, store {
        project_id: String,
        donor: address,
        amount: u64,
        fee_amount: u64,
    }

    public struct WithdrawalMade has drop, store {
        project_id: String,
        creator: address,
        amount: u64,
    }

    public struct RefundIssued has drop, store {
        project_id: String,
        donor: address,
        amount: u64,
    }

    /// Initialize the registry - this is called by the system during deployment
    fun init(ctx: &mut TxContext) {
        let registry = ProjectRegistry {
            id: object::new(ctx),
            projects: table::new(ctx),
            project_donations: table::new(ctx),
        };
        transfer::public_share_object(registry);
    }

    /// Create a new project with platform fee
    public entry fun create_project(
        registry: &mut ProjectRegistry,
        project_id: String,
        title: String,
        description: String,
        image_url: String,
        goal: u64,
        deadline: u64,
        mut fee_payment: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        assert!(!table::contains(&registry.projects, project_id), EProjectAlreadyExists);

        // Calculate fee (1% of goal)
        let fee_amount = goal * CREATION_FEE_PERCENT / 100;
        assert!(value(&fee_payment) >= fee_amount, EInsufficientFunds);

        // Split out the fee and send to vault wallet
        let fee = split(&mut fee_payment, fee_amount, ctx);
        public_transfer(fee, VAULT_WALLET);
        
        // Refund any remaining payment
        if (value(&fee_payment) > 0) {
            public_transfer(fee_payment, sender(ctx));
        } else {
            destroy_zero(fee_payment);
        };

        // Create the project
        let project = Project {
            id: project_id,
            title,
            description,
            image_url,
            creator: sender(ctx),
            goal,
            raised: 0,
            deadline,
            active: true,
        };

        // Store project data
        table::add(&mut registry.projects, project_id, project);
        table::add(&mut registry.project_donations, project_id, vec_map::empty());

        // Emit creation event
        event::emit(ProjectCreated {
            project_id,
            creator: sender(ctx),
            goal,
            deadline,
        });
    }

    /// Fund a project with platform fee
    public entry fun fund_project(
        registry: &mut ProjectRegistry,
        project_id: String,
        mut payment: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        assert!(table::contains(&registry.projects, project_id), EProjectNotFound);

        let project = table::borrow_mut(&mut registry.projects, project_id);
        assert!(project.active, EProjectNotFound);
        assert!(epoch(ctx) <= project.deadline, EDeadlinePassed);

        // Calculate donation amount and fee (1% of donation)
        let amount = value(&payment);
        let fee_amount = amount * DONATION_FEE_PERCENT / 100;
        let project_amount = amount - fee_amount;

        // Split out the fee and send to vault wallet
        let fee = split(&mut payment, fee_amount, ctx);
        public_transfer(fee, VAULT_WALLET);

        // Record donation
        let donor = sender(ctx);
        let donations = table::borrow_mut(&mut registry.project_donations, project_id);

        if (vec_map::contains(donations, &donor)) {
            let prev = vec_map::get_mut(donations, &donor);
            *prev = *prev + project_amount;
        } else {
            vec_map::insert(donations, donor, project_amount);
        }

        // Update project funding
        project.raised = project.raised + project_amount;

        // Transfer donation to project creator
        public_transfer(payment, project.creator);

        // Emit donation event
        event::emit(DonationReceived {
            project_id,
            donor,
            amount: project_amount,
            fee_amount,
        });
    }

    /// Withdraw funds after deadline or goal completion
    public entry fun withdraw(
        registry: &mut ProjectRegistry,
        project_id: String,
        ctx: &mut TxContext
    ) {
        assert!(table::contains(&registry.projects, project_id), EProjectNotFound);

        let project = table::borrow_mut(&mut registry.projects, project_id);
        assert!(sender(ctx) == project.creator, ENotCreator);
        assert!(epoch(ctx) > project.deadline || project.raised >= project.goal, EProjectStillActive);

        project.active = false;

        // Emit withdrawal event
        event::emit(WithdrawalMade {
            project_id,
            creator: project.creator,
            amount: project.raised,
        });
    }

    /// Get all funders for a project
    public fun get_project_funders(
        registry: &ProjectRegistry,
        project_id: String
    ): vector<address> {
        if (!table::contains(&registry.project_donations, project_id)) {
            return vector::empty<address>();
        };
        
        let donations = table::borrow(&registry.project_donations, project_id);
        vec_map::keys(donations)
    }

    /// Get donation amount for a specific donor
    public fun get_donation_amount(
        registry: &ProjectRegistry, 
        project_id: String,
        donor: address
    ): u64 {
        if (!table::contains(&registry.project_donations, project_id)) {
            return 0
        };
        
        let donations = table::borrow(&registry.project_donations, project_id);
        if (vec_map::contains(donations, &donor)) {
            *vec_map::get(donations, &donor)
        } else {
            0
        }
    }
    
    /// Bootstrap the Fundmint registry - public entry point for initialization
    /// This will be called after package deployment
    public entry fun bootstrap(ctx: &mut TxContext) {
        // The init function is automatically called when the module is published
        // This provides a public entry point for any additional initialization
    }
}