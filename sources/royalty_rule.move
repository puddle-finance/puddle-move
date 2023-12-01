module puddle_finance::royalty_rule{
    
    
    use sui::transfer_policy::{Self, TransferPolicy, TransferPolicyCap, TransferRequest};
    use sui::sui::{SUI};
    use sui::coin::{Coin};

    const MAX_BP: u16 = 10_000;
    const EOverMaxBp: u64 = 0;
    struct Rule has drop {}


    struct Config has store, drop{
        amount_bp: u16,
    }

    struct RoyaltyRequest{
        royalty: u64,
    }

    public entry fun add_royalty_rule<T>(
        policy: &mut TransferPolicy<T>,
        cap: &TransferPolicyCap<T>,
        amount_bp: u16,
    ){
        assert!(MAX_BP >= amount_bp, EOverMaxBp);

        transfer_policy::add_rule(
            Rule{}, 
            policy, 
            cap, 
            Config{
                amount_bp,
            }
        );
    }

    public fun calculate_royalty<T>(
        policy: &mut TransferPolicy<T>,
        paid: u64,
    ): RoyaltyRequest{
        let config: &Config = transfer_policy::get_rule(Rule{}, policy);
        let amount = (((config.amount_bp as u128) * (paid as u128)/ (MAX_BP as u128)) as u64);

        (RoyaltyRequest{ royalty: amount})

    }


    public fun handle_royalty<T>(
        policy: &mut TransferPolicy<T>,
        request: &mut TransferRequest<T>,
        royalty_req: RoyaltyRequest,
        fee: Coin<SUI>,
    ){
        let RoyaltyRequest{ royalty: _royalty, } = royalty_req;
        transfer_policy::add_to_balance(Rule{}, policy, fee);
        transfer_policy::add_receipt(Rule{}, request);
    }

    public fun remove_royalty_rule<T>(
        policy: &mut TransferPolicy<T>,
        cap: &TransferPolicyCap<T>,
    ){
        transfer_policy::remove_rule<T, Rule, Config>(policy, cap);
    }

    public fun get_royalty_value(royalty_req: &RoyaltyRequest): u64{
        royalty_req.royalty
    }
}