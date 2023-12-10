module puddle_finance::puddle{
    
    use sui::kiosk::{Kiosk};
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::object::{Self, UID, ID};
    use sui::coin::{Self, Coin};
    use sui::table::{Self, Table};
    use std::vector;
    use puddle_finance::cetus_invest::{Self};
    use puddle_finance::admin::{Self, TeamFund};
    use cetus_clmm::pool::{Pool};
    use cetus_clmm::config::GlobalConfig;
    use sui::bag::{Self, Bag};
    use std::string::{Self, String};
    use sui::clock::{Clock};

    const EOverMaxAmount: u64 = 0;
    const EDifferentOwner: u64 = 2;
    const EDifferentPuddle: u64 = 3;
    const EOverSharesAmount: u64 = 4;
    const EObjectCoinNotEnough: u64 = 5;
    const EPuddleAlreadyClosed: u64 = 8;
    const EPuddleAlreadyStopMint: u64 = 9;
    const EPuddleAlreadyStartMint: u64 = 10;
    const EStillHasInvestments: u64 = 11;
    const EPuddleNotFound: u64 = 12;
    const EPuddleNotClosed: u64 = 13;
    const EBalanceNotEnough: u64 = 14;
    const ENotInKiosk: u64 = 15;

    // shared object, puddle's all data
    struct Puddle<phantom T:drop> has key, store{
        id: UID,
        balance: Balance<T>,
        commission_percentage: u8,
        state: PuddleState, 
        holder_info: HolderInfo,
        market_info: MarketInfo,
        investments: InvestmentsRecord,
        metadata: PuddleMetaData,
    }

    // shared object, record all puddle address
    struct PuddleStatistic has key{
        id: UID,
        in_progress_puddles: vector<ID>,
        closed_puddles: vector<ID>,
        puddle_owner_table: Table<ID, address>,
    }

    // Puddles's field, record puddle state
    struct PuddleState has store{
        is_close: bool,
        is_stop_mint: bool,
    }

    // Puddles's field, puddle invest whitch item
    struct InvestmentsRecord has store{
        invests: vector<ID>,
        cost_table: Table<ID, u64>,
        balance_bag: Bag,
        total_rewards: u64,
    }


    // Puddles's field, record SaleItem object id
    struct MarketInfo has store{
        kiosk_objs: vector<ID>,
        kiosk_item_table: Table<ID, vector<ID>>, //kiosk -> item
    }

    // Puddles's field, user invest amount
    struct HolderInfo has store{
        holders: vector<address>, 
        holder_amount_table: Table<address, u64>,
    }

    // shared object, puddle's detail content
    struct PuddleMetaData has store {
        max_supply: u64,
        total_supply: u64,
        trader: address,
        name: String,
        desc: String,
    }

     // owner object, user invest puddle proof
    struct PuddleShare<phantom T: drop> has key, store{
        id: UID,
        shares: u64,
        puddle_id: ID,
        owner: address,
    }

    struct PuddleCap<phantom T: drop> has key{
        id: UID,
        puddle_id: ID,
    }

    //hot potato
    struct Increase {
        amount: u64,
    }
    

    // owner object, puddle owner proof
    fun init(ctx: &mut TxContext) {
        let puddle_statistics = PuddleStatistic{
            id: object::new(ctx),
            in_progress_puddles: vector::empty<ID>(),
            closed_puddles: vector::empty<ID>(),
            puddle_owner_table: table::new<ID, address>(ctx),
        };

        transfer::share_object(puddle_statistics);
    }
    #[lint_allow(self_transfer)]
    public fun new_puddle<T: drop>(
        max_amount: u64,
        trader: address,
        commission_percentage: u8,
        name: vector<u8>,
        desc: vector<u8>,
        ctx: &mut TxContext,
    ): Puddle<T>{
        let holder_info = HolderInfo{
            holders: vector::empty<address>(),
            holder_amount_table: table::new<address, u64>(ctx),
        };
        
        let market_info = MarketInfo{
            kiosk_objs: vector::empty<ID>(),
            kiosk_item_table: table::new<ID, vector<ID>>(ctx),
        };

        let metadata = PuddleMetaData{
            max_supply: max_amount,
            total_supply: 0,
            trader,
            name: string::utf8(name),
            desc:string::utf8(desc),
        };

        let state = PuddleState{
            is_close: false,
            is_stop_mint: false,
        };

        let investments = InvestmentsRecord{
            invests: vector::empty<ID>(),
            cost_table: table::new<ID, u64>(ctx),
            balance_bag: bag::new(ctx),
            total_rewards: 0,
        };

        Puddle<T>{
            id: object::new(ctx),
            balance: balance::zero<T>(),
            commission_percentage,
            state,
            holder_info,
            market_info,
            investments,
            metadata,
        }
    }

    #[lint_allow(share_owned)]
    public entry fun create_puddle<T: drop>(
        global: &mut PuddleStatistic,
        max_amount: u64,
        trader: address,
        commission_percentage: u8,
        name: vector<u8>,
        desc: vector<u8>,
        ctx: &mut TxContext,
    ){
        let puddle = new_puddle<T>(max_amount, trader, commission_percentage, name, desc, ctx);

        let puddle_cap = PuddleCap<T>{
            id: object::new(ctx),
            puddle_id: object::uid_to_inner(&puddle.id),
        };

        vector::push_back(&mut global.in_progress_puddles, object::uid_to_inner(&puddle.id));
        table::add<ID, address>(&mut global.puddle_owner_table, object::uid_to_inner(&puddle.id), tx_context::sender(ctx));
        transfer::public_share_object(puddle);
        transfer::transfer(puddle_cap, trader);
    }
    #[lint_allow(self_transfer)]
    public entry fun mint <T: drop>(
        puddle: &mut Puddle<T>,
        amount: u64, 
        coins: &mut Coin<T>,
        ctx: &mut TxContext
    ){
        assert!(puddle.state.is_stop_mint == false, EPuddleAlreadyStopMint);
        assert!(puddle.state.is_close ==false, EPuddleAlreadyClosed);
        assert!(coin::value(coins) >= amount, EObjectCoinNotEnough);
        assert!(amount + balance::value<T>(&puddle.balance) <= puddle.metadata.max_supply, EOverMaxAmount);
        
        let sender = tx_context::sender(ctx); 
        let invest_coins = coin::split<T>(coins,amount, ctx);
        let invest_balance = coin::into_balance<T>(invest_coins);

        puddle.metadata.total_supply = puddle.metadata.total_supply + amount;

        if (table::contains(&puddle.holder_info.holder_amount_table, sender)){
            let prievious_amount = table::remove(&mut puddle.holder_info.holder_amount_table, sender);
            let update_amount = prievious_amount + amount;
            table::add(&mut puddle.holder_info.holder_amount_table, sender, update_amount);
        }else{
            vector::push_back(&mut puddle.holder_info.holders, sender);
            table::add(&mut puddle.holder_info.holder_amount_table, sender, amount);
        };

        let shares = PuddleShare<T>{
            id: object::new(ctx),
            shares: balance::value<T>(&invest_balance),
            puddle_id: object::uid_to_inner(&puddle.id),
            owner: tx_context::sender(ctx),
        };
        
        balance::join<T>(&mut puddle.balance, invest_balance);

        transfer::public_transfer(shares, tx_context::sender(ctx));
    }

    public entry fun merge_shares<T: drop>(
        base: &mut PuddleShare<T>,
        shares_vec: vector<PuddleShare<T>>,
        _ctx: &mut TxContext,
    ){
        while(vector::length(&shares_vec) > 0){
            let shares2 = vector::pop_back<PuddleShare<T>>(&mut shares_vec);
            let PuddleShare<T>{
                id, 
                shares, 
                puddle_id,
                owner,
            } = shares2;

            assert!(base.owner == owner, EDifferentOwner);
            assert!(base.puddle_id == puddle_id, EDifferentPuddle);

            base.shares = base.shares + shares;

            object::delete(id);

            
        };

        vector::destroy_empty(shares_vec);
        
    }
    #[lint_allow(self_transfer)]
    public entry fun divide_shares<T: drop>(
        shares: &mut PuddleShare<T>,
        amount: u64,
        ctx: &mut TxContext,
    ){
        assert!(amount < shares.shares, EOverSharesAmount);

        shares.shares = shares.shares - amount;

        let new_shares = PuddleShare<T>{
            id: object::new(ctx),
            shares: amount,
            puddle_id: shares.puddle_id,
            owner: shares.owner,
        };

        transfer::public_transfer(new_shares, tx_context::sender(ctx));
    }
    #[lint_allow(custom_state_change)]
    public entry fun transfer_shares<T: drop>(
        puddle: &mut Puddle<T>,
        shares: PuddleShare<T>,
        to: address,
        ctx: &mut TxContext,
    ){
        let sender = tx_context::sender(ctx);
        let sender_amount = table::remove<address, u64>(&mut puddle.holder_info.holder_amount_table, sender);
        let receiver_amount = table::remove<address, u64>(&mut puddle.holder_info.holder_amount_table, to);
        sender_amount = sender_amount - shares.shares;
        receiver_amount = receiver_amount + shares.shares;
        if (sender_amount != 0){
            table::add<address, u64>(&mut puddle.holder_info.holder_amount_table, sender, sender_amount);
        };
        table::add<address, u64>(&mut puddle.holder_info.holder_amount_table, to ,receiver_amount);

        shares.owner = to;

        transfer::transfer(shares, to);
    }

    public entry fun withdraw_puddle_balance<T:drop>(
        _cap: &PuddleCap<T>,
        puddle: &mut Puddle<T>,
        ctx: &mut TxContext,
    ){
        assert!(puddle.state.is_close == true, EPuddleNotClosed);
        let i: u64 = 0;

        let total_supply = puddle.metadata.total_supply;
        while(i < vector::length(&puddle.holder_info.holders)){
            let user_addr = vector::pop_back<address>(&mut puddle.holder_info.holders);
            let total_balance = puddle.metadata.total_supply;
            let user_shares_amount = table::remove<address, u64>(&mut puddle.holder_info.holder_amount_table, user_addr);
            let user_get_amount =  total_balance * user_shares_amount / total_supply;
            
            if (total_balance < user_get_amount){
                let user_get_balance = balance::split<T>(&mut puddle.balance,total_balance );                
                let user_get_coin = coin::from_balance<T>(user_get_balance, ctx);
                transfer::public_transfer(user_get_coin, user_addr);
                break
            }else{
                let user_get_balance = balance::split<T>(&mut puddle.balance, user_get_amount);
                let user_get_coin = coin::from_balance<T>(user_get_balance, ctx);
                transfer::public_transfer(user_get_coin, user_addr);
            }
        }
    }
    #[lint_allow(self_transfer)]
    public entry fun close_puddle<T: drop>(
        cap: &PuddleCap<T>, 
        global: &mut PuddleStatistic,
        puddle: &mut Puddle<T>,
        _ctx: &mut TxContext,
    ){
        assert!(vector::is_empty<ID>(&puddle.investments.invests) == true, EStillHasInvestments);
        assert!(cap.puddle_id == object::uid_to_inner(&puddle.id), EDifferentPuddle);
        assert!(puddle.state.is_close ==false, EPuddleAlreadyClosed);
        puddle.state.is_close = true;
        
        let (is_existed, index_of_in_progress_puddle) = vector::index_of<ID>(&global.in_progress_puddles, &object::uid_to_inner(&puddle.id));
        assert!(is_existed, EPuddleNotFound);
        vector::swap_remove(&mut global.in_progress_puddles, index_of_in_progress_puddle);
        vector::push_back(&mut global.closed_puddles, object::uid_to_inner(&puddle.id));
    }

    public entry fun stop_mint<T:drop>(
        cap: &PuddleCap<T>, 
        puddle: &mut Puddle<T>,
        _ctx: &mut TxContext,
    ){
        assert!(cap.puddle_id == object::uid_to_inner(&puddle.id), EDifferentPuddle);
        assert!(puddle.state.is_stop_mint == false, EPuddleAlreadyStopMint);
        puddle.state.is_stop_mint = true;

    }

    public entry fun restart_mint<T: drop>(
        cap: &PuddleCap<T>, 
        puddle: &mut Puddle<T>,
        _ctx: &mut TxContext,
    ){
        assert!(cap.puddle_id == object::uid_to_inner(&puddle.id), EDifferentPuddle);
        assert!(puddle.state.is_stop_mint == true, EPuddleAlreadyStartMint);
        puddle.state.is_stop_mint = false;
    }

    public entry fun invest< CoinA: drop , CoinB: drop>(
        puddle_cap: &mut PuddleCap<CoinB>,
        puddle: &mut Puddle<CoinB>,
        config: &GlobalConfig,
        pool: &mut Pool<CoinA, CoinB>,
        amount: u64,
        sqrt_price_limit: u128,
        clock: &Clock,
        _ctx: &mut TxContext,
    ){
        assert!(balance::value<CoinB>(&puddle.balance) >= amount, EBalanceNotEnough);
        assert!(object::uid_to_inner(&puddle.id) == puddle_cap.puddle_id, EDifferentPuddle);
        
        let coin_b = &mut puddle.balance;
        
        let invest_balance = cetus_invest::invest<CoinA, CoinB>(
            config,
            pool,
            coin_b,
            amount,
            sqrt_price_limit,
            clock,
            );
        let investment_target = *object::borrow_id(pool);
        
        if (vector::contains<ID>(&puddle.investments.invests, &investment_target)){
            let previous_cost = table::remove(&mut puddle.investments.cost_table, investment_target);
            let final_cost = previous_cost + amount;
            table::add<ID, u64>(&mut puddle.investments.cost_table, investment_target, final_cost);

            balance::join<CoinA>(bag::borrow_mut<ID, Balance<CoinA>>(&mut puddle.investments.balance_bag, investment_target), invest_balance);
        }else{
            vector::push_back<ID>(&mut puddle.investments.invests, investment_target);
            table::add<ID, u64>(&mut puddle.investments.cost_table, investment_target, amount);
            bag::add<ID, Balance<CoinA>>(&mut puddle.investments.balance_bag, investment_target, invest_balance);
        } 
    }
        
    #[allow(unused_mut_ref)]
    public entry fun arbitrage<CoinA: drop , CoinB: drop >(
        _puddle_cap: &mut PuddleCap<CoinB>,
        puddle: &mut Puddle<CoinB>,
        config: &GlobalConfig,
        pool: &mut Pool<CoinA, CoinB>,
        amount: u64,
        sqrt_price_limit: u128,
        clock: &Clock,
        fund: &mut TeamFund,
        ctx: &mut TxContext,
    ){
        
        let investment_target = *object::borrow_id(pool);
        let coin_a = bag::borrow_mut<ID, Balance<CoinA>>(&mut puddle.investments.balance_bag, investment_target);
        assert!(amount <= balance::value<CoinA>(coin_a), EBalanceNotEnough);

        let receive_balance = cetus_invest::arbitrage<CoinA, CoinB>(
            config,
            pool,
            coin_a,
            amount,
            sqrt_price_limit,
            clock,
            );
        
        let cost = *table::borrow<ID, u64>(&mut puddle.investments.cost_table, investment_target) * amount / balance::value<CoinA>(coin_a) ;
        if (cost < balance::value<CoinB>(&receive_balance)){
            let total_rewards = (balance::value<CoinB>(&receive_balance) - cost);
            let reward_for_trader_amounts =  total_rewards * (puddle.commission_percentage as u64)* 10 / 1000;
            let rewards_for_team = total_rewards * 5 / 1000;
            let rewards_for_user_amount = total_rewards * (1000 - ((puddle.commission_percentage as u64)*10) -5) / 1000;

            admin::deposit<CoinB>(
                balance::split<CoinB>(&mut receive_balance, rewards_for_team), 
                fund,
                );

            let trader_rewards = balance::split<CoinB>(&mut receive_balance, reward_for_trader_amounts);
            transfer::public_transfer(coin::from_balance<CoinB>(trader_rewards, ctx), puddle.metadata.trader);


            
            let rewards = balance::split<CoinB>(&mut receive_balance, rewards_for_user_amount);
            give_out_bonus<CoinB>(puddle, &mut rewards, ctx);

            if (balance::value<CoinB>(&rewards) == 0){
                balance::destroy_zero(rewards);
            }else{
                balance::join<CoinB>(&mut puddle.balance, rewards);
            };
        
        };
        balance::join<CoinB>(&mut puddle.balance, receive_balance);  
    }

    public entry fun modify_puddle_name<T: drop >(
        cap: &PuddleCap<T>, 
        puddle: &mut Puddle<T>, 
        name: String, ){
            assert!(cap.puddle_id == object::uid_to_inner(&puddle.id), EDifferentPuddle);
            puddle.metadata.name = name;
    }

    public entry fun modify_puddle_desc<T: drop>(
        cap: &PuddleCap<T>, 
        puddle: &mut Puddle<T>, 
        desc: String, ){
            assert!(cap.puddle_id == object::uid_to_inner(&puddle.id), EDifferentPuddle);
            puddle.metadata.desc = desc;
    }

    public entry fun modify_puddle_trader<T: drop>(
        cap: PuddleCap<T>, 
        puddle: &mut Puddle<T>, 
        new_trader: address, ){
            assert!(cap.puddle_id == object::uid_to_inner(&puddle.id), EDifferentPuddle);
            puddle.metadata.trader = new_trader;
            transfer::transfer(cap, new_trader);

    }

    public entry fun modify_puddle_commission_percentage<T: drop>(
        cap: &PuddleCap<T>, 
        puddle: &mut Puddle<T>, 
        commission_percentage: u8, ){
            assert!(cap.puddle_id == object::uid_to_inner(&puddle.id), EDifferentPuddle);
            puddle.commission_percentage = commission_percentage;

    }

    fun give_out_bonus<T:drop>(
        puddle: &mut Puddle<T>,
        total_rewards: &mut Balance<T>,
        ctx: &mut TxContext,
    ){
        let i: u64 = 0;
        let total_supply = puddle.metadata.total_supply;

        while(i < vector::length(&puddle.holder_info.holders)){
            let user_addr = *vector::borrow<address>(&puddle.holder_info.holders, i);
            let user_shares_amount = table::remove<address, u64>(&mut puddle.holder_info.holder_amount_table, user_addr);
            let user_rewards =  balance::value<T>(total_rewards) * user_shares_amount / total_supply;
            
            if (balance::value<T>(total_rewards) < user_rewards){
                let user_reward_balance = balance::split<T>(total_rewards, user_rewards);                
                let user_reward_coin = coin::from_balance<T>(user_reward_balance, ctx);
                transfer::public_transfer(user_reward_coin, user_addr);
                break
            }else{
                let user_reward_balance = balance::split<T>(total_rewards, user_rewards);
                let user_reward_coin = coin::from_balance<T>(user_reward_balance, ctx);
                transfer::public_transfer(user_reward_coin, user_addr);
                i = i + 1;
                continue
            }
        }
    }

    public fun remove_market_item<T: drop>(
        kiosk_obj: &mut Kiosk,
        puddle: &mut Puddle<T>,
        item: ID,
    ){
        let kiosk_id = *object::borrow_id(kiosk_obj);
        let items = table::remove<ID, vector<ID>>(&mut puddle.market_info.kiosk_item_table,  kiosk_id);
        let (is_existed, index) = vector::index_of(&items, &item);
        assert!(is_existed, ENotInKiosk);
        vector::swap_remove(&mut items, index);
        table::add(&mut puddle.market_info.kiosk_item_table, kiosk_id, items);
    }

    public fun decrease_share_amount<T: drop>(
        puddle: &mut Puddle<T>,
        amount: u64,
        saler: address,
    ): Increase{
        let saler_amount = table::remove(&mut puddle.holder_info.holder_amount_table, saler);

        assert!(saler_amount >= amount, EBalanceNotEnough);
        
        saler_amount = saler_amount - amount;

        if (saler_amount != 0){
            table::add(&mut puddle.holder_info.holder_amount_table, saler, saler_amount);
        };
        Increase{
            amount: amount,
        }
    }

    public fun increase_share_amount<T: drop>(
        puddle: &mut Puddle<T>,
        buyer: address, 
        increase: Increase,
    ){
        let Increase{ amount, } = increase;
        let buyer_amount: u64 = 0;
        if (table::contains(&puddle.holder_info.holder_amount_table, buyer)){
            buyer_amount = table::remove(&mut puddle.holder_info.holder_amount_table, buyer);
        };

        buyer_amount = buyer_amount + amount;
        vector::push_back(&mut puddle.holder_info.holders, buyer);
        table::add(&mut puddle.holder_info.holder_amount_table, buyer, buyer_amount);
        
    }
    

    public fun add_market_info<T: drop>(
        puddle: &mut Puddle<T>,
        kiosk_obj: &mut Kiosk,
        item_id: ID,
    ){
        let kiosk_id =  *object:: borrow_id(kiosk_obj);

        if (!table::contains(&puddle.market_info.kiosk_item_table, kiosk_id)){
            vector::push_back(&mut puddle.market_info.kiosk_objs, kiosk_id);
            let items = vector::empty<ID>();
            vector::push_back(&mut items, item_id);
            table::add(&mut puddle.market_info.kiosk_item_table, kiosk_id, items);
        }else{
            let items = table::remove(&mut puddle.market_info.kiosk_item_table, kiosk_id);
            vector::push_back(&mut items, item_id);
            table::add(&mut puddle.market_info.kiosk_item_table, kiosk_id, items);
        }
       
    }

    public fun get_puddle_close_state<T: drop>(
        puddle: &Puddle<T>
    ): bool{
        puddle.state.is_close
    }
    
    public fun get_shares_of_puddle_share<T: drop>(
        share: &PuddleShare<T>
    ): u64{
        share.shares
    }

    public fun switch_owner<T: drop >(
        share: &mut PuddleShare<T>, 
        new_owner: address){
        share.owner = new_owner;
    }
}
