module puddle_finance::market{

    use sui::kiosk::{Self, Kiosk, KioskOwnerCap};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer::{Self};
    use sui::sui::{SUI};
    use sui::coin::{Self, Coin};
    use std::option::{Self,};
    use sui::package;
    use sui::transfer_policy::{Self, TransferPolicy, TransferPolicyCap};
    use sui::clock::{Clock};
    use sui::table::{Self,Table};
    use puddle_finance::royalty_rule::{Self};
    use puddle_finance::time_rule::{Self};
    use puddle_finance::puddle::{Self, Puddle, PuddleShare};
    use puddle_finance::admin::{Self,TeamFund};

    const EPuddleClosed: u64 = 0;
    const EAlreadyInKiosk: u64 = 1;
    const EBalanceNtEnough: u64 = 2;
    const ENotInKiosk: u64 = 3;
    const EUserAlreadyHaveKiosk: u64 = 4;
    const EOverShares:u64 = 5;

    struct MarketState has key{
        id: UID,
        item_price_table: Table<ID, u64>,
        user_kiosk_table: Table<address, ID>,
    }

    struct MARKET has drop{}

    #[allow(unused_function)]
    #[lint_allow(share_owned)]
    fun init (witness: MARKET, ctx: &mut TxContext){

        let publisher = package::claim(witness, ctx);

        let (policy, cap) = transfer_policy::new<PuddleShare<SUI>>(&publisher, ctx);

        let price_table = MarketState{
            id: object::new(ctx),
            item_price_table: table::new<ID, u64>(ctx),
            user_kiosk_table: table::new<address, ID>(ctx),
        };

        transfer::share_object(price_table);

        transfer::public_share_object(policy);
        transfer::public_transfer(cap, tx_context::sender(ctx));

        transfer::public_transfer(publisher, tx_context::sender(ctx));

    }
    #[lint_allow(share_owned, self_transfer)]
    public entry fun create_market(
        market_state: &mut MarketState,
        ctx: &mut TxContext,
    ){
        assert!(!table::contains<address, ID>(&market_state.user_kiosk_table, tx_context::sender(ctx)), EUserAlreadyHaveKiosk);
        let (kiosk, kiosk_cap) = kiosk::new(ctx);

        transfer::public_transfer(kiosk_cap, tx_context::sender(ctx));
        transfer::public_share_object(kiosk);
    }

    public entry fun sale_share<T: drop>(
        kiosk_obj: &mut Kiosk,
        kiosk_cap: &KioskOwnerCap,
        puddle: &mut Puddle<T>,
        price_table: &mut MarketState,
        share: PuddleShare<T>,
        amount: u64,
        price: u64,
        ctx: &mut TxContext,
    ){
        
        assert!(puddle::get_puddle_close_state(puddle) ==false, EPuddleClosed);
        
        let item_id = *object::borrow_id(&share);
        assert!(!kiosk::has_item(kiosk_obj, item_id), EAlreadyInKiosk);

        let shares = puddle::get_shares_of_puddle_share<T>(&share);
        assert!(shares > amount, EOverShares);
        
        puddle::divide_shares(&mut share, shares - amount, ctx);
        
        kiosk::place(kiosk_obj, kiosk_cap, share);
        kiosk::list<PuddleShare<T>>(kiosk_obj, kiosk_cap, item_id, price, );
        
        table::add(&mut price_table.item_price_table, item_id, price);
        puddle::add_market_info<T>(puddle, kiosk_obj, item_id);

    }

    // T is now just supported SUI.
    #[lint_allow(self_transfer)]
    public entry fun buy_share<T: drop>(
        kiosk_obj: &mut Kiosk,
        puddle: &mut Puddle<T>,
        price_table: &mut MarketState,
        policy: &mut TransferPolicy<PuddleShare<T>>,
        share_id: ID,
        payments: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext,
    ){
        assert!(puddle::get_puddle_close_state(puddle) ==false, EPuddleClosed);
        assert!(kiosk::has_item(kiosk_obj, share_id), ENotInKiosk);

        let buyer = tx_context::sender(ctx);
        let saler = kiosk::owner(kiosk_obj);

        let paid = table::remove<ID, u64>(&mut price_table.item_price_table, share_id);

        let increase = puddle::decrease_share_amount<T>(
            puddle,
            paid,
            saler,
        );

        puddle::increase_share_amount<T>(
            puddle,
            buyer,
            increase,
        );
        
        puddle::remove_market_item<T>(
            kiosk_obj,
            puddle,
            share_id,
        );


        
        let royalty_req = royalty_rule::calculate_royalty(policy, paid);
        let royalty_value = royalty_rule::get_royalty_value(&royalty_req);
        assert!( coin::value(&payments) >=  (royalty_value + paid), EBalanceNtEnough);
        
        let royalty_fee = coin::split(&mut payments, royalty_value, ctx); 
        let pay_item = coin::split(&mut payments, paid, ctx); 

        let (share, transfer_req) = kiosk::purchase<PuddleShare<T>>(
            kiosk_obj,
            share_id,
            pay_item,
        );

        royalty_rule::handle_royalty<PuddleShare<T>>(policy, &mut transfer_req, royalty_req, royalty_fee);
        time_rule::confirm_time<PuddleShare<T>>(policy, &mut transfer_req, clock);
        transfer::public_transfer(payments, tx_context::sender(ctx));

        transfer_policy::confirm_request(policy, transfer_req);
        transfer::public_transfer(share, tx_context::sender(ctx));
    }

    public entry fun withdraw_policy_rewards<T>(
        policy: &mut TransferPolicy<T>,
        policy_cap: &TransferPolicyCap<T>,
        fund: &mut TeamFund,
        ctx: &mut TxContext,
    ){
        let none = option::none<u64>();
        let rewards = transfer_policy::withdraw<T>(
            policy,
            policy_cap,
            none,
            ctx,
        );

        admin::deposit(coin::into_balance(rewards), fund);
    }


}