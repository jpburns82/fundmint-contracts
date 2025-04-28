module fundmint::fundmint_token {
    use sui::object as object;
    use sui::object::UID;
    use sui::tx_context as tx_context;
    use sui::tx_context::{TxContext, sender};
    use sui::transfer as transfer;
    use sui::transfer::{public_transfer, public_share_object};
    use sui::event as event;
    use sui::coin as coin;
    use sui::coin::{Coin, split, value, create_currency};
    use sui::balance as balance;
    use sui::balance::Balance;
    use std::vector;

    /// ----------------  CONSTANTS  ----------------
    const VAULT_WALLET: address = @0xcce6383bfe67b855f93e9d7ebb61296061c4cd15f303af884c3e0088a4f75e46;
    const TAX_BPS: u64 = 200;
    const BPS_DENOM: u64 = 10_000;

    /// ----------------  ERROR CODES  --------------
    const EInvalidAmount: u64 = 0x1;

    /// ----------------  TOKEN TYPES  --------------
    public struct FMNT has store, drop {}

    public struct TokenMetadata has key, store {
        id: UID,
        name: vector<u8>,
        symbol: vector<u8>,
        decimals: u8,
        total_supply: u64,
    }

    public struct VaultBalance has key, store {
        id: UID,
        balance: balance::Balance<FMNT>,
    }

    /// ----------------  EVENTS  -------------------
    /// TokensMinted event is safe to keep copy ability as it only contains primitive types
    public struct TokensMinted has copy, drop, store { 
        recipient: address, 
        amount: u64 
    }
    /// TokensBurned event is safe to keep copy ability as it only contains primitive types
    public struct TokensBurned has copy, drop, store { 
        burner: address, 
        amount: u64 
    }
    /// TaxTaken event is safe to keep copy ability as it only contains primitive types
    public struct TaxTaken has copy, drop, store { 
        payer: address, 
        tax_amt: u64 
    }

    /// -------------  INITIALIZATION  --------------
    ///
    /// This initializes the FMNT token with proper TreasuryCap pattern.
    /// Admin must manually store TreasuryCap after publishing.
    ///
    fun init(ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency<FMNT>(
            b"Fundmint",
            b"FMNT",
            6u8,
            b"Fundmint Token for crowdfunding platform",
            b"", // icon_url
            b"", // project_url
            ctx
        );
        
        // Create the metadata object that will be shared
        let token_metadata = TokenMetadata {
            id: object::new(ctx),
            name: b"Fundmint",
            symbol: b"FMNT",
            decimals: 6,
            total_supply: 1_000_000_000 * 1_000_000,
        };
        
        // Share metadata with the network
        transfer::public_share_object(metadata);
        transfer::public_share_object(token_metadata);
        
        // Transfer treasury_cap to sender (admin will manage it)
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
    }

    /// -------------  TAXED TRANSFER  --------------
    ///
    public entry fun transfer_with_tax(
        mut payment: Coin<FMNT>,
        recipient: address,
        ctx: &mut TxContext
    ) {
        let amt = value(&payment);
        assert!(amt > 0, EInvalidAmount);

        let tax = amt * TAX_BPS / BPS_DENOM;
        let user_amt = amt - tax;

        let tax_coin = split(&mut payment, tax, ctx);
        public_transfer(tax_coin, VAULT_WALLET);
        public_transfer(payment, recipient);

        event::emit(TaxTaken { payer: sender(ctx), tax_amt: tax });
    }

    // Voting functionality moved to fundmint::voting module
    
    /// Bootstrap the FMNT token - this is the public entry point
    /// Called after the package is published
    public entry fun bootstrap(ctx: &mut TxContext) {
        // The init function is automatically called when the module is published
        // This bootstrap function will be called manually after publishing
        // to perform any additional initialization tasks
    }
}
