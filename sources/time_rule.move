module puddle_finance::time_rule{

    use sui::transfer_policy::{Self, TransferPolicy, TransferPolicyCap, TransferRequest};
    use sui::clock::{Self,Clock};
    
    const ETooSoon: u64 = 0;

    struct Config has store, drop {
        start_time : u64,
    }

    struct Rule has drop {}

    public entry fun add_time_rule<T>(
        policy: &mut TransferPolicy<T>,
        cap: &TransferPolicyCap<T>,
        start_time: u64,
    ){
        transfer_policy::add_rule(
            Rule{}, 
            policy, 
            cap,
            Config{
                start_time,
            });
    }

    public fun confirm_time<T>(
        policy: &mut TransferPolicy<T>,
        request: &mut TransferRequest<T>,
        clock: &Clock,
    ){
        let config: &Config = transfer_policy::get_rule(
            Rule{},
            policy,
        );
        assert!(config.start_time <= clock::timestamp_ms(clock), ETooSoon);
        transfer_policy::add_receipt(Rule{}, request);
    }

    public fun remove_royalty_rule<T>(
        policy: &mut TransferPolicy<T>,
        cap: &TransferPolicyCap<T>,
    ){
        transfer_policy::remove_rule<T, Rule, Config>(policy, cap);
    }

}