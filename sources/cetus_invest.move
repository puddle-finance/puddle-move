module puddle_finance::cetus_invest{
    use cetus_clmm::pool::{Self, Pool};
    use cetus_clmm::config::GlobalConfig;
    use sui::balance::{Self, Balance};
    use sui::clock::{Clock};
    friend puddle_finance::puddle;

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
        let (in_amount, out_amount) = (pool::swap_pay_amount(&flash_receipt),balance::value(&receive_a));
        
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
        let (in_amount, out_amount) = (
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