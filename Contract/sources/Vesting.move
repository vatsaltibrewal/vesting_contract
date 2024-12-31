module VestingContract1::test123 {
    use std::signer;
    use std::timestamp;
    use std::vector;
    use std::error;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::account;
    use aptos_framework::event;

    /// Error codes
    const ENO_VESTING_MANAGER: u64 = 1;
    const ENO_CLAIMABLE_AMOUNT: u64 = 2;
    const EINVALID_VESTING_PARAMS: u64 = 3;
    const ENOT_OWNER: u64 = 4;
    const EALREADY_INITIALIZED: u64 = 5;
    const EINVALID_BENEFICIARY: u64 = 6;
    const ESCHEDULE_NOT_FOUND: u64 = 7;

    struct VestingSchedule has key, copy, store {
        owner: address,
        beneficiary: address,
        total_amount: u64,
        start_time: u64,
        cliff_duration: u64,
        total_duration: u64,
        claimed_amount: u64,
        is_active: bool,
    }

    struct VestingManager has key, copy {
        owner: address,
        schedules: vector<VestingSchedule>,
    }

    /// Events
    #[event]
    struct VestingScheduleCreatedEvent has drop, store {
        owner: address,
        beneficiary: address,
        total_amount: u64,
        start_time: u64,
    }

    #[event]
    struct TokensClaimedEvent has drop, store {
        beneficiary: address,
        amount: u64,
        timestamp: u64,
    }

    fun init_module(account: &signer) {
        let address = signer::address_of(account);
        assert!(!exists<VestingManager>(address), error::already_exists(EALREADY_INITIALIZED));
        
        move_to(account, VestingManager {
            owner: address,
            schedules: vector::empty(),
        });
    }

    public entry fun create_vesting_schedule<CoinType>(
        owner: &signer,
        beneficiary: address,
        total_amount: u64,
        start_time: u64,
        cliff_duration: u64,
        total_duration: u64
    ) acquires VestingManager {
        let owner_address = signer::address_of(owner);
        
        // Validate parameters
        assert!(exists<VestingManager>(owner_address), error::not_found(ENO_VESTING_MANAGER));
        assert!(cliff_duration <= total_duration, error::invalid_argument(EINVALID_VESTING_PARAMS));
        assert!(total_amount > 0, error::invalid_argument(EINVALID_VESTING_PARAMS));
        assert!(beneficiary != @0x0, error::invalid_argument(EINVALID_BENEFICIARY));
        
        let manager = borrow_global_mut<VestingManager>(owner_address);
        assert!(manager.owner == owner_address, error::permission_denied(ENOT_OWNER));

        // Create new schedule
        let schedule = VestingSchedule {
            owner: owner_address,
            beneficiary,
            total_amount,
            start_time,
            cliff_duration,
            total_duration,
            claimed_amount: 0,
            is_active: true,
        };

        vector::push_back(&mut manager.schedules, schedule);

        // Emit event
        event::emit(VestingScheduleCreatedEvent {
            owner: owner_address,
            beneficiary,
            total_amount,
            start_time,
        });
    }

    public fun calculate_vested_amount(schedule: &VestingSchedule, current_time: u64): u64 {
        if (!schedule.is_active) {
            return 0
        };
        if (current_time < schedule.start_time + schedule.cliff_duration) {
            return 0
        };

        let elapsed_time = current_time - schedule.start_time;
        if (elapsed_time >= schedule.total_duration) {
            return schedule.total_amount - schedule.claimed_amount
        };

        let vested_amount = (elapsed_time * schedule.total_amount) / schedule.total_duration;
        vested_amount - schedule.claimed_amount
    }

    public entry fun claim_tokens<CoinType>(
        account: &signer
    ) acquires VestingManager {
        let user_address = signer::address_of(account);
        let current_time = timestamp::now_seconds();
        
        // Ensure user has a vesting manager
        assert!(exists<VestingManager>(user_address), error::not_found(ENO_VESTING_MANAGER));
        
        let manager = borrow_global_mut<VestingManager>(user_address);
        let total_claimable = 0u64;
        
        let i = 0;
        while (i < vector::length(&manager.schedules)) {
            let schedule = vector::borrow_mut(&mut manager.schedules, i);
            if (schedule.beneficiary == user_address && schedule.is_active) {
                let claimable = calculate_vested_amount(schedule, current_time);
                if (claimable > 0) {
                    schedule.claimed_amount = schedule.claimed_amount + claimable;
                    total_claimable = total_claimable + claimable;
                    
                    // Check if fully vested
                    if (schedule.claimed_amount == schedule.total_amount) {
                        schedule.is_active = false;
                    };
                };
            };
            i = i + 1;
        };

        assert!(total_claimable > 0, error::invalid_state(ENO_CLAIMABLE_AMOUNT));

        // Transfer tokens
        let coins = coin::withdraw<CoinType>(account, total_claimable);
        coin::deposit(user_address, coins);

        // Emit claim event
        event::emit(TokensClaimedEvent {
            beneficiary: user_address,
            amount: total_claimable,
            timestamp: current_time,
        });
    }

    #[view]
    public fun get_vesting_schedules(account: address): vector<VestingSchedule> acquires VestingManager {
        assert!(exists<VestingManager>(account), error::not_found(ENO_VESTING_MANAGER));
        let manager = borrow_global<VestingManager>(account);
        manager.schedules
    }

    #[view]
    public fun get_claimable_amount(
        beneficiary: address,
        owner: address
    ): u64 acquires VestingManager {
        assert!(exists<VestingManager>(owner), error::not_found(ENO_VESTING_MANAGER));
        
        let manager = borrow_global<VestingManager>(owner);
        let current_time = timestamp::now_seconds();
        let total_claimable = 0u64;
        
        let i = 0;
        while (i < vector::length(&manager.schedules)) {
            let schedule = vector::borrow(&manager.schedules, i);
            if (schedule.beneficiary == beneficiary && schedule.is_active) {
                total_claimable = total_claimable + calculate_vested_amount(schedule, current_time);
            };
            i = i + 1;
        };
        
        total_claimable
    }

    public entry fun pause_vesting_schedule(
        owner: &signer,
        beneficiary: address,
        schedule_index: u64
    ) acquires VestingManager {
        let owner_address = signer::address_of(owner);
        assert!(exists<VestingManager>(owner_address), error::not_found(ENO_VESTING_MANAGER));
        
        let manager = borrow_global_mut<VestingManager>(owner_address);
        assert!(manager.owner == owner_address, error::permission_denied(ENOT_OWNER));
        assert!(schedule_index < vector::length(&manager.schedules), error::invalid_argument(ESCHEDULE_NOT_FOUND));
        
        let schedule = vector::borrow_mut(&mut manager.schedules, schedule_index);
        assert!(schedule.beneficiary == beneficiary, error::invalid_argument(EINVALID_BENEFICIARY));
        schedule.is_active = false;
    }

    public entry fun resume_vesting_schedule(
        owner: &signer,
        beneficiary: address,
        schedule_index: u64
    ) acquires VestingManager {
        let owner_address = signer::address_of(owner);
        assert!(exists<VestingManager>(owner_address), error::not_found(ENO_VESTING_MANAGER));
        
        let manager = borrow_global_mut<VestingManager>(owner_address);
        assert!(manager.owner == owner_address, error::permission_denied(ENOT_OWNER));
        assert!(schedule_index < vector::length(&manager.schedules), error::invalid_argument(ESCHEDULE_NOT_FOUND));
        
        let schedule = vector::borrow_mut(&mut manager.schedules, schedule_index);
        assert!(schedule.beneficiary == beneficiary, error::invalid_argument(EINVALID_BENEFICIARY));
        schedule.is_active = true;
    }

    #[test_only]
    struct TestCoin {}

    #[test(owner = @0x1, beneficiary = @0x2)]
    fun test_vesting_flow(
        owner: &signer,
        beneficiary: &signer
    ) acquires VestingManager {
        // Setup test environment
        //timestamp::set_time_has_started(account);
        let start_time = timestamp::now_seconds();
        
        // Initialize vesting manager
        init_module(owner);
        
        // Create vesting schedule
        create_vesting_schedule<TestCoin>(
            owner,
            signer::address_of(beneficiary),
            1000, // total amount
            start_time,
            100,  // cliff duration
            1000  // total duration
        );
        
        // Check initial claimable amount (should be 0 due to cliff)
        let claimable = get_claimable_amount(
            signer::address_of(beneficiary),
            signer::address_of(owner)
        );
        assert!(claimable == 0, 1);
        
        // Fast forward past cliff
        timestamp::fast_forward_seconds(150);
        
        // Check claimable amount again (should be > 0)
        let claimable = get_claimable_amount(
            signer::address_of(beneficiary),
            signer::address_of(owner)
        );
        assert!(claimable > 0, 2);
    }
}