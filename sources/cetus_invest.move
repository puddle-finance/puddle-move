module puddle_finance::cetus_invest{
    use cetus_clmm::pool::{Self, Pool};
    use cetus_clmm::config::GlobalConfig;
    use sui::balance::{Self, Balance};
    use sui::clock::{Clock};
    use std::string::{Self, String};
    use std::type_name::{Self};
    use sui::object::{Self, UID, ID};
    use sui::table::{Self, Table};
    use sui::tx_context::{Self, TxContext};
    use std::vector;
    use sui::transfer;

    friend puddle_finance::puddle;

    const ECoinNotExisted: u64 = 0;
    const ECoinAlreadyExisted: u64 = 1;
    

    struct CetusInfo has key {
        id: UID,
        global_config: ID,
        supported_coins: vector<String>,
        coin_icon_table: Table<String, String>,
        coin_symb_table: Table<String, String>,
    }

    struct InvestmentManagedCap has key{
        id: UID,
    }

    fun init (ctx: &mut TxContext){
        //default setting
        let global_config = object::id_from_address(@0xdaa46292632c3c4d8f31f23ea0f9b36a28ff3677e9684980e4438403a67a3d8f);
        let cetus_info = CetusInfo{
            id: object::new(ctx),
            global_config,
            supported_coins: vector::empty<String>(),
            coin_icon_table: table::new<String, String>(ctx),
            coin_symb_table: table::new<String, String>(ctx),
        }; 

        let cap = InvestmentManagedCap{
            id: object::new(ctx),
        };
        transfer::transfer(cetus_info, tx_context::sender(ctx));
        transfer::transfer(cap, tx_context::sender(ctx));
    }

    public entry fun add_investment<T: drop>(
        _cap: &InvestmentManagedCap,
        cetus_info: &mut CetusInfo,
        symbol: String, 
        icon: String, ){
            let coin_type= string::from_ascii(type_name::into_string(type_name::get<T>()));
            assert!(!vector::contains<String>(&cetus_info.supported_coins, &coin_type), ECoinAlreadyExisted);
            vector::push_back<String>(&mut cetus_info.supported_coins, coin_type);
            table::add<String, String>(&mut cetus_info.coin_symb_table, coin_type, symbol);
            table::add<String, String>(&mut cetus_info.coin_icon_table, coin_type, icon);
    }

    public entry fun modify_coin_symb<T:drop>(
        _cap: &InvestmentManagedCap,
        cetus_info: &mut CetusInfo,
        symbol: String, ){
            let coin_type= string::from_ascii(type_name::into_string(type_name::get<T>()));
            assert!(vector::contains<String>(&cetus_info.supported_coins, &coin_type), ECoinNotExisted);
            let _ = table::remove<String, String>(&mut cetus_info.coin_symb_table, coin_type);
            table::add<String, String>(&mut cetus_info.coin_symb_table, coin_type, symbol);
    }

    public entry fun modify_coin_icon<T:drop>(
        _cap: &InvestmentManagedCap,
        cetus_info: &mut CetusInfo,
        icon: String, ){
            let coin_type= string::from_ascii(type_name::into_string(type_name::get<T>()));
            assert!(vector::contains<String>(&cetus_info.supported_coins, &coin_type), ECoinNotExisted);
            let _ = table::remove<String, String>(&mut cetus_info.coin_icon_table, coin_type);
            table::add<String, String>(&mut cetus_info.coin_icon_table, coin_type, icon);
    }

    public entry fun remove_coin<T:drop>(
        _cap: &InvestmentManagedCap,
        cetus_info: &mut CetusInfo,){
            let coin_type= string::from_ascii(type_name::into_string(type_name::get<T>()));
            let (is_existed, i)= vector::index_of<String>(&cetus_info.supported_coins, &coin_type);
            assert!(is_existed, ECoinAlreadyExisted);
            vector::swap_remove<String>(&mut cetus_info.supported_coins, i);
            table::remove<String, String>(&mut cetus_info.coin_icon_table, coin_type);
            table::remove<String, String>(&mut cetus_info.coin_symb_table, coin_type);
    }


    public entry fun modify_global_config(
        _cap: &InvestmentManagedCap,
        cetus_info: &mut CetusInfo,
        global_config: ID,){
            cetus_info.global_config = global_config;
    }


    public(friend) fun invest<CoinA, CoinB>(
        config: &GlobalConfig,
        pool: &mut Pool<CoinA, CoinB>,
        coin_b: &mut Balance<CoinB>,
        amount: u64,
        sqrt_price_limit: u128,
        clock: &Clock,
    ):Balance<CoinA>{
        let (receive_a, receive_b, flash_receipt) = pool::flash_swap<CoinA, CoinB>(
            config,
            pool,
            false,
            true,
            amount,
            sqrt_price_limit,
            clock,
        );
        let (in_amount, _out_amount) = (pool::swap_pay_amount(&flash_receipt),balance::value(&receive_a));
        
        // pay for flash swap
        let (pay_coin_a, pay_coin_b) = (balance::zero<CoinA>(), balance::split(coin_b, in_amount));

        balance::join<CoinB>( coin_b, receive_b);

        pool::repay_flash_swap<CoinA, CoinB>(
            config,
            pool,
            pay_coin_a,
            pay_coin_b,
            flash_receipt
        );

        return receive_a
        
    } 

    public(friend) fun arbitrage<CoinA, CoinB>(
        config: &GlobalConfig,
        pool: &mut Pool<CoinA, CoinB>,
        coin_a: &mut Balance<CoinA>,
        amount: u64,
        sqrt_price_limit: u128,
        clock: &Clock,
    ):Balance<CoinB>{

        let (receive_a, receive_b, flash_receipt) = pool::flash_swap<CoinA, CoinB>(
            config,
            pool,
            true,
            true,
            amount,
            sqrt_price_limit,
            clock,
        );
        let (in_amount, _out_amount) = (
            pool::swap_pay_amount(&flash_receipt), balance::value(&receive_b));
        
        // pay for flash swap
        let (pay_coin_a, pay_coin_b) = (balance::split(coin_a, in_amount), balance::zero<CoinB>());
        
        balance::join<CoinA>(coin_a, receive_a);

        pool::repay_flash_swap<CoinA, CoinB>(
            config,
            pool,
            pay_coin_a,
            pay_coin_b,
            flash_receipt
        );

        return receive_b
    }

}