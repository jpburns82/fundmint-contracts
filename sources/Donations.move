module fundmint::donations {
    use sui::object as object;
    use sui::object::UID;
    use sui::tx_context as tx_context;
    use sui::tx_context::{TxContext, sender};
    use sui::coin as coin;
    use sui::coin::{Coin, value, split};
    use sui::transfer as transfer;
    use sui::transfer::{public_transfer, public_share_object};
    use sui::event as event;
    use sui::sui::SUI;
    use sui::table as table;
    use sui::table::Table;
    use std::vector;

    /// Constants
    const EInvalidAmount: u64 = 0x1;
    const EProjectNotFound: u64 = 0x2;
    const ENoDonationFound: u64 = 0x3;

    const PLATFORM_FEE_BPS: u64 = 100; // 1% platform fee (basis points)
    
    /// Vault wallet for platform fees
    const VAULT_WALLET: address = @0xcce6383bfe67b855f93e9d7ebb61296061c4cd15f303af884c3e0088a4f75e46;

    /// Events
    public struct DonationMade has drop, store {
        project_id: vector<u8>,
        donor: address,
        amount: u64,
        platform_fee: u64,
    }

    public struct RefundIssued has drop, store {
        project_id: vector<u8>,
        donor: address,
        amount: u64,
    }

    /// Records an individual donation
    public struct Donation has key, store {
        id: UID,
        donor: address,
        project_id: vector<u8>,
        amount: u64,
        timestamp: u64,
        escrow: Coin<SUI>, // Store donation as Coin<SUI> in contract control
    }

    /// Book holding donations per project
    public struct DonationBook has key, store {
        id: UID,
        donations: Table<vector<u8>, Table<address, Donation>>,
        vault_wallet: address,
    }

    /// Initialize the DonationBook
    public entry fun create_donation_book(ctx: &mut TxContext) {
        let donation_book = DonationBook {
            id: object::new(ctx),
            donations: table::new(ctx),
            vault_wallet: VAULT_WALLET,
        };
        transfer::public_share_object(donation_book);
    }

    /// Make a donation to a project
    public entry fun donate(
        book: &mut DonationBook,
        project_id: vector<u8>,
        mut payment: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        let amount = value(&payment);
        assert!(amount > 0, EInvalidAmount);

        let donor = sender(ctx);

        // Calculate platform fee
        let fee_amount = (amount * PLATFORM_FEE_BPS) / 10_000;
        let donation_amount = amount - fee_amount;

        // Split payment
        let fee_coin = split(&mut payment, fee_amount, ctx);

        // Send platform fee to vault
        public_transfer(fee_coin, VAULT_WALLET);

        // Record the donation into escrow
        if (!table::contains(&book.donations, project_id)) {
            table::add(&mut book.donations, project_id, table::new(ctx));
        };

        let project_table = table::borrow_mut(&mut book.donations, project_id);
        table::add(project_table, donor, Donation {
            id: object::new(ctx),
            donor,
            project_id,
            amount: donation_amount,
            timestamp: tx_context::epoch(ctx),
            escrow: payment, // hold their donation inside the system
        });

        event::emit(DonationMade {
            project_id,
            donor,
            amount: donation_amount,
            platform_fee: fee_amount,
        });
    }

    /// Refund a donation back to a donor
    public entry fun refund(
        book: &mut DonationBook,
        project_id: vector<u8>,
        donor: address,
        ctx: &mut TxContext
    ) {
        assert!(table::contains(&book.donations, project_id), EProjectNotFound);
        let project_table = table::borrow_mut(&mut book.donations, project_id);
        assert!(table::contains(project_table, donor), ENoDonationFound);

        let donation = table::remove(project_table, donor);

        // Return the escrowed donation directly
        public_transfer(donation.escrow, donor);

        event::emit(RefundIssued {
            project_id,
            donor,
            amount: donation.amount,
        });
    }

    /// Get donation amount for a specific donor and project
    public fun get_donation_amount(
        book: &DonationBook,
        project_id: vector<u8>,
        donor: address
    ): u64 {
        if (!table::contains(&book.donations, project_id)) {
            return 0;
        };
        let project_table = table::borrow(&book.donations, project_id);
        if (!table::contains(project_table, donor)) {
            return 0;
        };
        let donation = table::borrow(project_table, donor);
        donation.amount
    }
}
