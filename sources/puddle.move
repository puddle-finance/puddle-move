module puddle_finance::puddle{
    
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::object::{Self, UID, ID};
    use sui::coin::{Self, Coin, TreasuryCap};
    use std::option::{Self, Option};
    use sui::table::{Self, Table};
    use std::vector;
    use puddle_finance::cetus_invest::{Self};
    use cetus_clmm::pool::{Self, Pool};
    use cetus_clmm::config::GlobalConfig;
    use sui::bag::{Self, Bag};
    use std::string::{Self, String};
    use sui::clock::{Self, Clock};
    use std::debug::{Self};

    const EOverMaxAmount: u64 = 0;
    const ENotEnough: u64 = 1;
    const EDifferentOwner: u64 = 2;
    const EDifferentPuddle: u64 = 3;
    const EOverSharesAmount: u64 = 4;
    const EObjectCoinNotEnough: u64 = 5;
    const EItemIsSaled: u64 = 6;
    const EPuddleClosed: u64 = 7;
    const EPuddleAlreadyClosed: u64 = 8;
    const EPuddleAlreadyStopMint: u64 = 9;
    const EPuddleAlreadyStartMint: u64 = 10;
    const EStillHasInvestments: u64 = 11;
    const EPuddleNotFound: u64 = 12;
    const EPuddleNotClosed: u64 = 13;
    const EBalanceNotEnough: u64 = 14;

    // shared object, puddle's all data
    struct Puddles<phantom T:drop> has key, store{
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
    struct PuddleStatistics has key{
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
        items: vector<ID>,
        item_listing_table: Table<ID, bool>,
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
    struct PuddleShares<phantom T: drop> has key, store{
        id: UID,
        shares: u64,
        puddle_id: ID,
        owner: address,
    }

    // shared object, if user shell PuddleShares
    struct SaleItem<phantom T: drop> has key{
        id: UID,
        price: u64,
        item: Option<PuddleShares<T>>,
    }


    struct PuddleCap<phantom T: drop> has key{
        id: UID,
        puddle_id: ID,
    }

    // owner object, puddle owner proof
    fun init(ctx: &mut TxContext) {
        let puddle_statistics = PuddleStatistics{
            id: object::new(ctx),
            in_progress_puddles: vector::empty<ID>(),
            closed_puddles: vector::empty<ID>(),
            puddle_owner_table: table::new<ID, address>(ctx),
        };

        transfer::share_object(puddle_statistics);
    }
    
    public fun new_puddle<T: drop>(
        max_amount: u64,
        trader: address,
        commission_percentage: u8,
        name: vector<u8>,
        desc: vector<u8>,
        ctx: &mut TxContext,
    ): Puddles<T>{
        let holder_info = HolderInfo{
            holders: vector::empty<address>(),
            holder_amount_table: table::new<address, u64>(ctx),
        };
        
        let market_info = MarketInfo{
            items: vector::empty<ID>(),
            item_listing_table: table::new<ID, bool>(ctx),
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

        Puddles<T>{
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

    public entry fun create_puddle<T: drop>(
        global: &mut PuddleStatistics,
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

    public entry fun mint <T: drop>(
        puddle: &mut Puddles<T>,
        amount: u64, 
        coins: &mut Coin<T>,
        ctx: &mut TxContext
    ){
        assert!(puddle.state.is_stop_mint == false, EPuddleAlreadyStopMint);
        assert!(puddle.state.is_close ==false, EPuddleAlreadyClosed);
        assert!(coin::value(coins) >= amount, EObjectCoinNotEnough);
        assert!(coin::value(coins) + balance::value<T>(&puddle.balance) <= puddle.metadata.max_supply, EOverMaxAmount);
        
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

        let shares = PuddleShares<T>{
            id: object::new(ctx),
            shares: balance::value<T>(&invest_balance),
            puddle_id: object::uid_to_inner(&puddle.id),
            owner: tx_context::sender(ctx),
        };
        
        balance::join<T>(&mut puddle.balance, invest_balance);

        transfer::public_transfer(shares, tx_context::sender(ctx));
    }

    public entry fun sale_shares<T:drop>(
        puddle: &mut Puddles<T>,
        shares: PuddleShares<T>,
        price: u64,
        ctx: &mut TxContext,
    ){
        assert!(puddle.state.is_close ==false, EPuddleClosed);

        let sale_item = SaleItem<T>{
            id: object::new(ctx),
            price,
            item: option::none(),
        };
        option::fill(&mut sale_item.item, shares);

        table::add<ID, bool>(&mut puddle.market_info.item_listing_table, object::uid_to_inner(&sale_item.id), true);
        vector::push_back<ID>(&mut puddle.market_info.items, object::uid_to_inner(&sale_item.id));

        transfer::share_object(sale_item);
    }

    public entry fun cancel_sale_shares<T: drop>(
        product: &mut SaleItem<T>,
        ctx: &mut TxContext,
    ){
        let puddle_share = option::extract(&mut product.item);
        transfer::public_transfer(puddle_share, tx_context::sender(ctx));
    }

    public entry fun buy_shares<T: drop>(
        puddle: &mut Puddles<T>,
        product: &mut SaleItem<T>,
        payments: &mut Coin<T>,
        ctx: &mut TxContext,
    ){
        assert!(puddle.state.is_close == false, EPuddleClosed);
        assert!(option::is_some<PuddleShares<T>>(&product.item),EItemIsSaled);
        let puddle_shares = option::extract(&mut product.item);
        assert!(coin::value<T>(payments) >= product.price, ENotEnough);
        
        let buyer = tx_context::sender(ctx);
        let saler = puddle_shares.owner;
        let item_price = product.price;
        let coins_for_item = coin::split<T>(payments, item_price, ctx);

        let saler_amount = table::remove<address, u64>(&mut puddle.holder_info.holder_amount_table, puddle_shares.owner);
        let buyer_amount = table::remove<address, u64>(&mut puddle.holder_info.holder_amount_table, buyer);
        saler_amount = saler_amount - puddle_shares.shares;
        buyer_amount = buyer_amount + puddle_shares.shares;

        if (saler_amount != 0){
            table::add<address, u64>(&mut puddle.holder_info.holder_amount_table, saler, saler_amount);
        };
        table::add<address, u64>(&mut puddle.holder_info.holder_amount_table, buyer, buyer_amount);
        

        let _ = table::remove<ID, bool>(&mut puddle.market_info.item_listing_table, object::uid_to_inner(&product.id));
        table::add<ID, bool>(&mut puddle.market_info.item_listing_table, object::uid_to_inner(&product.id),false);

        puddle_shares.owner = buyer;
        
        transfer::public_transfer(coins_for_item, puddle_shares.owner);
        transfer::public_transfer(puddle_shares, tx_context::sender(ctx));
        
    }

    public entry fun merge_shares<T: drop>(
        shares1: &mut PuddleShares<T>,
        shares2: PuddleShares<T>,
        _ctx: &mut TxContext,
    ){
        
        let PuddleShares<T>{
            id: id2, 
            shares: shares2, 
            puddle_id: puddle_id2,
            owner: owner2,} = shares2;

        assert!(shares1.owner == owner2, EDifferentOwner);
        assert!(shares1.puddle_id == puddle_id2, EDifferentPuddle);
        
        shares1.shares = shares1.shares + shares2;

        object::delete(id2);
    }

    public entry fun divide_shares<T: drop>(
        shares: &mut PuddleShares<T>,
        amount: u64,
        ctx: &mut TxContext,
    ){
        assert!(amount < shares.shares, EOverSharesAmount);

        shares.shares = shares.shares - amount;

        let new_shares = PuddleShares<T>{
            id: object::new(ctx),
            shares: amount,
            puddle_id: shares.puddle_id,
            owner: shares.owner,
        };

        transfer::public_transfer(new_shares, tx_context::sender(ctx));
    }

    public entry fun transfer_shares<T: drop>(
        puddle: &mut Puddles<T>,
        shares: PuddleShares<T>,
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
        puddle: &mut Puddles<T>,
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

    public entry fun close_puddle<T: drop>(
        cap: &PuddleCap<T>, 
        global: &mut PuddleStatistics,
        puddle: &mut Puddles<T>,
        _ctx: &mut TxContext,
    ){
        assert!(vector::is_empty<ID>(&puddle.investments.invests) == true, EStillHasInvestments);
        assert!(cap.puddle_id == object::uid_to_inner(&puddle.id), EDifferentPuddle);
        assert!(puddle.state.is_close ==false, EPuddleAlreadyClosed);
        puddle.state.is_close = true;
        
        let (is_existed, index_of_in_progress_puddle) = vector::index_of<ID>(&mut global.in_progress_puddles, &object::uid_to_inner(&puddle.id));
        assert!(is_existed, EPuddleNotFound);
        vector::swap_remove(&mut global.in_progress_puddles, index_of_in_progress_puddle);
        vector::push_back(&mut global.closed_puddles, object::uid_to_inner(&puddle.id));
    }

    public entry fun stop_mint<T:drop>(
        cap: &PuddleCap<T>, 
        puddle: &mut Puddles<T>,
        _ctx: &mut TxContext,
    ){
        assert!(cap.puddle_id == object::uid_to_inner(&puddle.id), EDifferentPuddle);
        assert!(puddle.state.is_stop_mint == false, EPuddleAlreadyStopMint);
        puddle.state.is_stop_mint = true;

    }

    public entry fun restart_mint<T: drop>(
        cap: &PuddleCap<T>, 
        puddle: &mut Puddles<T>,
        _ctx: &mut TxContext,
    ){
        assert!(cap.puddle_id == object::uid_to_inner(&puddle.id), EDifferentPuddle);
        assert!(puddle.state.is_stop_mint == true, EPuddleAlreadyStartMint);
        puddle.state.is_stop_mint = false;
    }

    public entry fun invest< CoinA: drop , CoinB: drop>(
        _puddle_cap: &mut PuddleCap<CoinB>,
        puddle: &mut Puddles<CoinB>,
        config: &GlobalConfig,
        pool: &mut Pool<CoinA, CoinB>,
        amount: u64,
        sqrt_price_limit: u128,
        clock: &Clock,
        ctx: &mut TxContext,
    ){
        assert!(balance::value<CoinB>(&puddle.balance) >= amount, EBalanceNotEnough);
        
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
            debug::print(bag::borrow_mut<ID, Balance<CoinA>>(&mut puddle.investments.balance_bag, investment_target));

        }else{
            vector::push_back<ID>(&mut puddle.investments.invests, investment_target);
            table::add<ID, u64>(&mut puddle.investments.cost_table, investment_target, amount);
            bag::add<ID, Balance<CoinA>>(&mut puddle.investments.balance_bag, investment_target, invest_balance);
            debug::print(bag::borrow_mut<ID, Balance<CoinA>>(&mut puddle.investments.balance_bag, investment_target));
        } 
    }
        
    
    public entry fun arbitrage<CoinA: drop , CoinB: drop >(
        _puddle_cap: &mut PuddleCap<CoinB>,
        puddle: &mut Puddles<CoinB>,
        config: &GlobalConfig,
        pool: &mut Pool<CoinA, CoinB>,
        amount: u64,
        sqrt_price_limit: u128,
        clock: &Clock,
        ctx: &mut TxContext,
    ){
        
        let investment_target = *object::borrow_id(pool);
        let coin_a = bag::borrow_mut<ID, Balance<CoinA>>(&mut puddle.investments.balance_bag, investment_target);
        debug::print(coin_a);
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
            let reward_for_trader_amounts =  total_rewards * (puddle.commission_percentage as u64) / 100;
            let rewards_for_user_amount = total_rewards * (100 - (puddle.commission_percentage as u64)) / 100;

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

    fun give_out_bonus<T:drop>(
        puddle: &mut Puddles<T>,
        total_rewards: &mut Balance<T>,
        ctx: &mut TxContext,
    ){
        let i: u64 = 0;
        let total_supply = puddle.metadata.total_supply;

        while(i < vector::length(&puddle.holder_info.holders)){
            let user_addr = *vector::borrow<address>(&mut puddle.holder_info.holders, i);
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

    fun coins_to_balances<T>(coins: vector<Coin<T>>):vector<Balance<T>>{
        let res = vector::empty<Balance<T>>();

        while(vector::length(&coins) > 0){
            let coin_member = vector::pop_back<Coin<T>>(&mut coins);
            vector::push_back<Balance<T>>(&mut res, coin::into_balance(coin_member));
        };
        vector::destroy_empty<Coin<T>>(coins);

        return res
    }

    
}

