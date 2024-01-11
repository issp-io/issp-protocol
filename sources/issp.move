module issp::issp {
    use std::option;
    use sui::coin::{Self};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    struct ISSP has drop {}

    fun init(
        witness: ISSP,
        ctx: &mut TxContext,
    ) {
        let (treasury_cap, coin_metadata) = coin::create_currency(
            witness,
            6,
            b"ISSP",
            b"ISSP Coin",
            b"Sui20 Coin for ISSP",
            option::none(),
            ctx
        );
        transfer::public_freeze_object(coin_metadata);
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
    }
}
