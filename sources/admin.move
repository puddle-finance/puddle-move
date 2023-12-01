module puddle_finance::admin{

    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self};
    use sui::bag::{Self, Bag};
    use std::string::{Self, String};
    use sui::vec_set::{Self, VecSet};
    use sui::tx_context::{Self, TxContext};
    use std::vector;
    use std::type_name::{Self};
    

    const EAlreadyAdmin: u64 = 0;
    const EAdminNotFound:u64 = 1;
    const EBalanceNotEnough: u64 = 2;

    friend puddle_finance::puddle;
    friend puddle_finance::market;

    struct AdminVec has key {
        id: UID,
        admins: VecSet<address>,
    }

    struct AdminCap has key {
        id: UID,
    }

    struct TeamFund has key{
        id: UID,
        balance_bag: Bag,
        key_vector: vector<String>,
    }

    fun init(ctx: &mut TxContext){
        let team_funds = TeamFund{
            id: object::new(ctx),
            balance_bag: bag::new(ctx),
            key_vector: vector::empty<String>(),
        };

        let admin_cap = AdminCap{id: object::new(ctx),};

        let admin_vec = AdminVec{
            id: object::new(ctx),
            admins: vec_set::empty<address>(),
        };

        vec_set::insert<address>(&mut admin_vec.admins, tx_context::sender(ctx));

        transfer::share_object(team_funds);
        transfer::transfer(admin_cap, tx_context::sender(ctx));
        transfer::share_object(admin_vec);
    }

    public entry fun add_admin(
        _cap: &AdminCap, 
        admin_vector: &mut AdminVec,
        new_member: address, 
        ctx: &mut TxContext){
            assert!(!vec_set::contains<address>(&admin_vector.admins, &new_member),EAlreadyAdmin );
            vec_set::insert<address>(&mut admin_vector.admins, new_member);

            let admin_cap = AdminCap{id: object::new(ctx),};
            transfer::transfer(admin_cap, new_member);
    }

    public entry fun remove_admin(
        _cap: &AdminCap, 
        admin_vector: &mut AdminVec,
        remove_member: address,
    ){
        vec_set::remove<address>(&mut admin_vector.admins, &remove_member);
    }

    public(friend) fun deposit<T>(
        bal: Balance<T>,
        funds: &mut TeamFund,
    ){
        let coin_type= string::from_ascii(type_name::into_string(type_name::get<T>()));
    
        if (vector::contains<String>(&funds.key_vector, &coin_type)){
            let bal_mut = bag::borrow_mut<String, Balance<T>>(&mut funds.balance_bag, coin_type);
            balance::join<T>(bal_mut, bal);
        }else{
            vector::push_back<String>(&mut funds.key_vector, coin_type);
            bag::add<String, Balance<T>>(&mut funds.balance_bag, coin_type, bal);
        };
        
    }

    public entry fun withdraw<T>(
         _cap: &AdminCap, 
         admin_vector:&mut AdminVec,
         fund: &mut TeamFund,
         to: address,
         amount: u64,
         ctx: &mut TxContext,
    ){
        let coin_type= string::from_ascii(type_name::into_string(type_name::get<T>()));
        assert!(vec_set::contains<address>(&admin_vector.admins, &tx_context::sender(ctx)), EAdminNotFound);
        let total_balance = bag::borrow_mut<String, Balance<T>>(&mut fund.balance_bag, coin_type);
        assert!(balance::value<T>(total_balance) >= amount, EBalanceNotEnough);

        let withdraw_balance = balance::split(total_balance, amount);

        let withdraw_coins = coin::from_balance<T>(withdraw_balance, ctx);
        transfer::public_transfer(withdraw_coins, to);

    }
}