module fundmint::rewards {
    use sui::object as object;
    use sui::object::UID;
    use sui::tx_context as tx_context;
    use sui::tx_context::{TxContext, sender, epoch};
    use sui::transfer as transfer;
    use sui::transfer::{public_transfer, public_share_object};
    use sui::event as event;
    use sui::coin as coin;
    use sui::coin::{Coin, value};
    use sui::sui::SUI;
    use sui::table as table;
    use sui::table::Table;
    use std::vector;

    /// Error codes
    const EInvalidRewardAmount: u64 = 0x1;
    
    /// Vault wallet for platform fees
    const VAULT_WALLET: address = @0xcce6383bfe67b855f93e9d7ebb61296061c4cd15f303af884c3e0088a4f75e46;

    /// Reward record - can be copied because it only contains primitive types
    public struct Reward has copy, drop, store {
        rewardee: address,
        project_owner: address,
        amount: u64,
        timestamp: u64,
    }

    /// Registry for all rewards
    public struct RewardBook has key, store {
        id: UID,
        rewards: Table<address, vector<Reward>>, // rewardee -> list of rewards
    }

    /// Reward distribution event
    public struct RewardDistributed has copy, drop, store {
        project_owner: address,
        rewardee: address,
        amount: u64,
    }

    /// Create a new RewardBook
    public entry fun create_reward_book(ctx: &mut TxContext) {
        let reward_book = RewardBook {
            id: object::new(ctx),
            rewards: table::new(ctx),
        };
        transfer::public_share_object(reward_book);
    }

    /// Reward a user for contributing (restricted to SUI only)
    public entry fun reward_user(
        book: &mut RewardBook,
        project_owner: address,
        rewardee: address,
        mut payment: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        let amount = value(&payment);
        assert!(amount > 0, EInvalidRewardAmount);

        let reward_record = Reward {
            rewardee,
            project_owner,
            amount,
            timestamp: epoch(ctx),
        };

        if (table::contains(&book.rewards, rewardee)) {
            let mut existing_rewards = table::remove(&mut book.rewards, rewardee);
            vector::push_back(&mut existing_rewards, reward_record);
            table::add(&mut book.rewards, rewardee, existing_rewards);
        } else {
            let mut rewards = vector::empty<Reward>();
            vector::push_back(&mut rewards, reward_record);
            table::add(&mut book.rewards, rewardee, rewards);
        }

        public_transfer(payment, rewardee);

        event::emit(RewardDistributed {
            project_owner,
            rewardee,
            amount,
        });
    }

    /// Retrieve rewards for a specific user
    public fun get_rewards_for_user(book: &RewardBook, rewardee: address): vector<Reward> {
        if (table::contains(&book.rewards, rewardee)) {
            *table::borrow(&book.rewards, rewardee)
        } else {
            vector::empty()
        }
    }
}