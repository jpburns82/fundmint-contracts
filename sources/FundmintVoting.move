module fundmint::voting {

    use sui::object as object;
    use sui::object::UID;
    use sui::tx_context as tx_context;
    use sui::tx_context::{TxContext, sender, epoch};
    use sui::coin as coin;
    use sui::coin::{Coin, value, split, join, into_balance, from_balance};
    use sui::transfer as transfer;
    use sui::transfer::{public_transfer, public_share_object};
    use sui::balance as balance;
    use sui::balance::Balance;
    use sui::sui::SUI;
    use sui::table as table;
    use sui::table::{Table, values};
    use sui::event as event;
    use fundmint::fundmint_token::FMNT;
    use std::vector;

    /// Error Codes
    const EInvalidStakeAmount: u64 = 0x1;
    const EVoteNotFound: u64 = 0x2;
    const EInvalidAmount: u64 = 0x3;
    
    /// Token Vote structure for FMNT token voting
    public struct TokenVote has drop, store {
        project_id: vector<u8>,
        voter: address,
        amount: u64,
        timestamp: u64,
    }

    /// Registry for token votes using FMNT tokens
    public struct VotingRegistry has key, store {
        id: UID,
        votes: Table<vector<u8>, TokenVote>,
    }
    
    /// Event emitted when a token vote is cast
    public struct VoteCast has drop, store { 
        project_id: vector<u8>, 
        voter: address, 
        amount: u64 
    }

    /// Represents the state of a vote
    public enum VoteChoice has copy, drop, store {
        Approve,
        Reject,
    }

    /// Represents a single vote
    public struct Vote has key, store {
        id: UID,
        project_owner: address,
        voter: address,
        choice: VoteChoice,
        amount_locked: u64,
        timestamp: u64,
    }

    /// Voting ledger for all votes
    public struct VotingBook has key, store {
        id: UID,
        votes: vector<Vote>,
        locked_stakes: Table<address, balance::Balance<SUI>>,
    }

    /// Create the voting book (only once)
    public entry fun create_voting_book(ctx: &mut TxContext) {
        let voting_book = VotingBook {
            id: object::new(ctx),
            votes: vector::empty<Vote>(),
            locked_stakes: table::new(ctx),
        };
        transfer::public_share_object(voting_book);
    }

    /// Cast a vote for a project (locks SUI as commitment)
    public entry fun cast_vote(
        book: &mut VotingBook,
        project_owner: address,
        stake: Coin<SUI>,
        choice: u8, // 0 = Approve, 1 = Reject
        ctx: &mut TxContext
    ) {
        let amount = value(&stake);
        assert!(amount > 0, EInvalidStakeAmount);

        let voter_addr = sender(ctx);

        // Convert the staked Coin<SUI> into a Balance<SUI> to lock inside VotingBook
        let locked_balance = into_balance(stake);

        // Store the balance inside the locked_stakes table
        table::add(&mut book.locked_stakes, voter_addr, locked_balance);

        // Record the vote
        let vote = Vote {
            id: object::new(ctx),
            project_owner,
            voter: voter_addr,
            choice: if (choice == 0) { VoteChoice::Approve } else { VoteChoice::Reject },
            amount_locked: amount,
            timestamp: epoch(ctx),
        };

        vector::push_back(&mut book.votes, vote);
    }

    /// Allow voters to reclaim their locked stake
    public entry fun unlock_stake(
        book: &mut VotingBook,
        ctx: &mut TxContext
    ) {
        let voter_addr = sender(ctx);

        assert!(table::contains(&book.locked_stakes, voter_addr), EVoteNotFound);

        // Retrieve the locked balance
        let locked = table::remove(&mut book.locked_stakes, voter_addr);

        // Convert Balance<SUI> back into Coin<SUI>
        let refund = from_balance(locked, ctx);

        // Return the staked SUI to the voter
        public_transfer(refund, voter_addr);
    }

    /// Get all votes - returns a copy of the votes vector
    public fun get_votes(book: &VotingBook): vector<Vote> {
        *&book.votes
    }
    
    /// Get votes by project owner - returns vector of votes for a specific project owner
    public fun get_votes_by_owner(book: &VotingBook, owner: address): vector<Vote> {
        let result = vector::empty<Vote>();
        let i = 0;
        let len = vector::length(&book.votes);
        
        while (i < len) {
            let vote = vector::borrow(&book.votes, i);
            if (vote.project_owner == owner) {
                vector::push_back(&mut result, *vote);
            };
            i = i + 1;
        };
        
        result
    }

    /// Create a new token voting registry
    public entry fun create_voting_registry(ctx: &mut TxContext) {
        let registry = VotingRegistry { 
            id: object::new(ctx), 
            votes: table::new(ctx) 
        };
        transfer::public_share_object(registry);
    }

    /// Vote for a project using FMNT tokens
    public entry fun vote_for_project(
        registry: &mut VotingRegistry,
        project_id: vector<u8>,
        amount: u64,
        payment: Coin<FMNT>,
        ctx: &mut TxContext
    ) {
        assert!(amount > 0, EInvalidAmount);
        let payer = sender(ctx);
        let paid = value(&payment);
        assert!(paid >= amount, EInvalidAmount);

        let balance = into_balance(payment);

        table::add(&mut registry.votes, project_id, TokenVote {
            project_id, voter: payer, amount, timestamp: epoch(ctx)
        });

        // refund change if overpaid
        if (paid > amount) {
            let refund = from_balance(balance::withdraw(&mut balance, paid - amount), ctx);
            public_transfer(refund, payer);
        }

        event::emit(VoteCast { project_id, voter: payer, amount });
    }

    /// Get a specific token vote
    public fun get_token_vote(
        registry: &VotingRegistry,
        project_id: vector<u8>
    ): TokenVote {
        assert!(table::contains(&registry.votes, project_id), EVoteNotFound);
        *table::borrow(&registry.votes, project_id)
    }

    /// Get all token votes
    public fun get_all_token_votes(
        registry: &VotingRegistry
    ): vector<TokenVote> {
        table::values(&registry.votes)
    }
}
