module issp::sui20 {
    use std::string::{String, utf8};
    use std::vector;
    use sui::bag::{Self, Bag};
    use sui::balance::{Self, Balance};
    use sui::clock::{Clock, timestamp_ms};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::object::{Self, UID};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::tx_context::{TxContext, sender};
    use sui::table::Table;
    use sui::table;
    use sui::package;
    use sui::display;
    use sui::event::emit;

    /* ------------------------ 1.1 constant ------------------------ */
    // only for upgrade
    const MAX_ALLOWED_UPGRADE_VERSION: u64 = 4;
    const TOP_HOLDERS_LENGTH: u64 = 20;

    /* ------------------------ 1.2 errors ------------------------ */
    const ERR_ONLY_ALLOWED_VERSION: u64 = 1000;
    const ERR_ONLY_NOT_PAUSED: u64 = 1001;
    const ERR_SUI20_TICK_EXISTS: u64 = 1002;
    const ERR_SUI20_TICK_NOT_EXISTS: u64 = 1003;
    const ERR_SUI20_SUPPLY_EXCEED_MAX: u64 = 1004;
    const ERR_SUI20_FEE_NOT_ENOUGH: u64 = 1005;
    const ERR_BALANCE_NOT_ENOUGH: u64 = 1006;
    const ERR_INVALID_AMOUNT: u64 = 1007;
    const ERR_SUI20_TO_COIN_NOT_ENABLED: u64 = 1008;
    const ERR_INVALID_TICK_LENGTH: u64 = 1009;
    const ERR_INVALID_TICK: u64 = 1010;
    const ERR_DUPLICATE_TICK: u64 = 1011;
    const ERR_SUI20_NOT_MATCH: u64 = 1012;
    const ERR_NOT_START: u64 = 1013;
    const ERR_SUI20_MINT_EXCEED_LIMIT: u64 = 1014;
    const ERR_MINT_TOO_FAST: u64 = 1015;
    const ERR_MINT_EXCEED_LIMIT_PER_USER: u64 = 1016;

    /* ------------------------ 2. object ------------------------ */
    struct AdminCap has key, store {
        id: UID,
    }

    struct SUI20 has drop {}

    struct Global has key, store {
        id: UID,
        is_paused: bool,

        sui20tokens: Bag, // tickName => Sui20Data
        fee: Balance<SUI>,

        // for upgrade
        current_version: u64,
        // reserve for future upgrades
        upgrade_bag: Bag,
    }

    struct UserInfo has store, copy, drop {
        minted_amount: u64,
        last_mint_at: u64,
        hold_amount: u64,
    }

    struct Sui20Meta has store {
        tick: String,
        max: u64,
        limit: u64,
        decimals: u8,
        fee: u64,
        start_at: u64,
    }

    struct Sui20Data has store {
        meta: Sui20Meta,
        enable_to_coin: bool,
        total_minted: u64,

        txs: u64,
        user_infos: Table<address, UserInfo>, // address => UserInfo
        users: vector<address>, // top holders

        mint_cd: u64,
        max_mint_per_user: u64,

        // reserve for future upgrades
        upgrade_bag: Bag,
    }

    struct Sui20 has key, store {
        id: UID,
        tick: String,
        amount: u64,
    }

    struct Sui20WrapCoin<phantom T> has store {
        treasury_cap: TreasuryCap<T>,
    }

    /* ------------------------ 3. events ------------------------ */
    struct QueryDataEvent has copy, drop {
        // metadata
        tick: String,
        start_at: u64,
        total_cap: u64,
        limit_per_mint: u64,
        decimals: u8,
        mint_fee: u64,
        mint_cd: u64,
        max_mint_per_user: u64,

        // states
        total_minted: u64,
        remain_supply: u64,
        txs: u64,

        // user
        user_minted_amount: u64,
        user_hold_amount: u64,
        user_last_mint_at: u64,
    }

    struct QueryUsersEvent has copy, drop {
        users: vector<address>,
        minted_amounts: vector<u64>,
    }

    /* ------------------------ 4-1 init function ------------------------ */
    fun init(otw: SUI20, ctx: &mut TxContext) {
        let global = Global {
            id: object::new(ctx),
            is_paused: false,

            sui20tokens: bag::new(ctx),
            fee: balance::zero(),

            current_version: 0,
            upgrade_bag: bag::new(ctx),
        };
        transfer::public_share_object(global);
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        transfer::public_transfer(admin_cap, sender(ctx));

        // nft display
        let publisher = package::claim(otw, ctx);
        let keys = vector[
            utf8(b"name"),
            utf8(b"image_url"),
            utf8(b"description"),
        ];
        let values = vector[
            utf8(b"{tick}"),
            utf8(b"https://issp.io/assets/{tick}.svg"),
            utf8(b"{\"p\":\"sui-20\",\"tick\":\"{tick}\",\"amt\":\"{amount}\"}"),
        ];
        let sui20_display = display::new_with_fields<Sui20>(
            &publisher, keys, values, ctx
        );
        display::update_version(&mut sui20_display);
        transfer::public_transfer(sui20_display, sender(ctx));
        transfer::public_transfer(publisher, sender(ctx));
    }

    /* ------------------------ 4-2 only operator ------------------------ */
    public fun set_paused(global: &mut Global, _admin_cap: &mut AdminCap, paused: bool) {
        global.is_paused = paused;
    }

    public fun set_version(global: &mut Global, _admin_cap: &mut AdminCap, current_version: u64) {
        global.current_version = current_version;
    }

    public fun update_enable_to_coin(
        global: &mut Global,
        _admin_cap: &mut AdminCap,
        tick: String,
        enable: bool,
        _ctx: &mut TxContext,
    ) {
        assert!(bag::contains(&global.sui20tokens, tick), ERR_SUI20_TICK_NOT_EXISTS);
        let data = bag::borrow_mut<String, Sui20Data>(&mut global.sui20tokens, tick);
        data.enable_to_coin = enable;
    }

    public fun update_mint_cd(
        global: &mut Global,
        _admin_cap: &mut AdminCap,
        tick: String,
        mint_cd: u64,
        _ctx: &mut TxContext,
    ) {
        assert!(bag::contains(&global.sui20tokens, tick), ERR_SUI20_TICK_NOT_EXISTS);
        let data = bag::borrow_mut<String, Sui20Data>(&mut global.sui20tokens, tick);
        data.mint_cd = mint_cd;
    }

    /* ------------------------ 4-3 public ------------------------ */
    public fun deploy(
        global: &mut Global,
        clock: &Clock,
        tick: vector<u8>,
        max: u64,
        limit: u64,
        decimals: u8,
        fee: u64,
        mint_start_at: u64,
        max_mint_per_user: u64,
        ctx: &mut TxContext,
    ) {
        only_allowed_version(global);
        only_not_paused(global);

        let now_seconds = timestamp_ms(clock) / 1000;

        let tickName = check_tick(tick, global);
        assert!(!bag::contains(&global.sui20tokens, tickName), ERR_SUI20_TICK_EXISTS);

        let mint_time = now_seconds;
        if (mint_start_at > now_seconds) {
            mint_time = mint_start_at;
        };

        let meta = Sui20Meta {
            tick: tickName,
            max,
            limit,
            decimals,
            fee,
            start_at: mint_time,
        };
        let sui20Data = Sui20Data {
            meta,
            enable_to_coin: false,
            total_minted: 0,

            txs: 0,
            user_infos: table::new<address, UserInfo>(ctx),
            users: vector::empty(),

            mint_cd: 0,
            max_mint_per_user,

            upgrade_bag: bag::new(ctx),
        };

        bag::add(&mut global.sui20tokens, tickName, sui20Data);
    }

    public fun mint(
        global: &mut Global,
        clock: &Clock,
        tick: String,
        amount: u64,
        suiCoin: Coin<SUI>,
        ctx: &mut TxContext,
    ): Coin<SUI> {
        only_allowed_version(global);
        only_not_paused(global);

        let user = sender(ctx);
        let now_seconds = timestamp_ms(clock) / 1000;
        assert!(bag::contains(&global.sui20tokens, tick), ERR_SUI20_TICK_NOT_EXISTS);

        let data = bag::borrow_mut<String, Sui20Data>(&mut global.sui20tokens, tick);
        assert!(now_seconds >= data.meta.start_at, ERR_NOT_START);
        assert!(amount <= data.meta.limit, ERR_SUI20_MINT_EXCEED_LIMIT);
        assert!(data.total_minted + amount <= data.meta.max, ERR_SUI20_SUPPLY_EXCEED_MAX);
        assert!(coin::value(&suiCoin) >= data.meta.fee, ERR_SUI20_FEE_NOT_ENOUGH);

        // update nft data
        balance::join(&mut global.fee, coin::into_balance(coin::split(&mut suiCoin, data.meta.fee, ctx)));
        data.total_minted = data.total_minted + amount;
        data.txs = data.txs + 1;

        // update userInfo
        if (!table::contains(&data.user_infos, user)) {
            let default_user_info = UserInfo {
                minted_amount: 0,
                last_mint_at: 0,
                hold_amount: 0,
            };
            table::add(&mut data.user_infos, user, default_user_info);
        };

        let user_minted_amount= {
            let info = table::borrow_mut(&mut data.user_infos, user);
            assert!(now_seconds >= info.last_mint_at + data.mint_cd, ERR_MINT_TOO_FAST);

            info.minted_amount = info.minted_amount + amount;
            info.last_mint_at = now_seconds;
            info.hold_amount = info.hold_amount + amount;

            assert!(info.minted_amount <= data.max_mint_per_user, ERR_MINT_EXCEED_LIMIT_PER_USER);

            info.minted_amount
        };

        // update top holder
        let len = vector::length(&data.users);
        let topInfo;
        let topUser;
        if (!vector::contains(&data.users, &user)) {
            let i = 0;
            while (i < len) {
                topUser = *vector::borrow(&data.users, i);
                topInfo = table::borrow(&data.user_infos, topUser);
                if (user_minted_amount > topInfo.minted_amount) {
                    vector::insert(&mut data.users, user, i);
                    break
                };
                i = i + 1;
            };

            let newLen = vector::length(&data.users);
            if (newLen == len && len < TOP_HOLDERS_LENGTH) {
                vector::push_back(&mut data.users, user);
            } else if (newLen > TOP_HOLDERS_LENGTH) {
                vector::pop_back(&mut data.users);
            }
        };

        let sui20 = Sui20 {
            id: object::new(ctx),
            tick: data.meta.tick,
            amount,
        };
        transfer::public_transfer(sui20, user);
        suiCoin
    }

    public fun transfer(
        global: &mut Global,
        tick: String,
        sui20: vector<Sui20>,
        to: address,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        only_allowed_version(global);
        only_not_paused(global);

        let user = sender(ctx);
        assert!(bag::contains(&global.sui20tokens, tick), ERR_SUI20_TICK_NOT_EXISTS);

        let data = bag::borrow_mut<String, Sui20Data>(&mut global.sui20tokens, tick);
        assert!(amount > 0, ERR_INVALID_AMOUNT);
        let total_amount = 0;

        while (!vector::is_empty(&sui20)) {
            let sui20 = vector::pop_back(&mut sui20);
            let Sui20 { id, tick: _tick, amount } = sui20;
            assert!(_tick == tick, ERR_SUI20_NOT_MATCH);
            object::delete(id);
            total_amount = total_amount + amount;
        };
        assert!(total_amount >= amount, ERR_BALANCE_NOT_ENOUGH);
        vector::destroy_empty(sui20);

        let sui20 = Sui20 {
            id: object::new(ctx),
            tick: data.meta.tick,
            amount,
        };
        transfer::public_transfer(sui20, to);
        let left = total_amount - amount;
        if (left > 0) {
            let sui20 = Sui20 {
                id: object::new(ctx),
                tick: data.meta.tick,
                amount: left,
            };
            transfer::public_transfer(sui20, user);
        };
    }

    public fun batch_transfer(
        global: &mut Global,
        sui20: Sui20,
        receivers: vector<address>,
        amt_per_address: u64,
        ctx: &mut TxContext,
    ) {
        only_allowed_version(global);
        only_not_paused(global);

        let Sui20 { id, tick, amount } = sui20;
        assert!(bag::contains(&global.sui20tokens, tick), ERR_SUI20_TICK_NOT_EXISTS);
        assert!(amt_per_address > 0, ERR_INVALID_AMOUNT);

        assert!(amount == amt_per_address * vector::length(&receivers), ERR_INVALID_AMOUNT);
        object::delete(id);

        while (!vector::is_empty(&receivers)) {
            let receiver = vector::pop_back(&mut receivers);
            let sui20 = Sui20 {
                id: object::new(ctx),
                tick,
                amount: amt_per_address,
            };
            transfer::public_transfer(sui20, receiver);
        };
    }

    public fun merge(
        global: &mut Global,
        tick: String,
        sui20s: vector<Sui20>,
        ctx: &mut TxContext,
    ): (Sui20, u64) {
        only_allowed_version(global);
        only_not_paused(global);

        assert!(bag::contains(&global.sui20tokens, tick), ERR_SUI20_TICK_NOT_EXISTS);

        let total_amount = 0;
        while (!vector::is_empty(&sui20s)) {
            let sui20 = vector::pop_back(&mut sui20s);
            let Sui20 { id, tick: _tick, amount } = sui20;
            assert!(_tick == tick, ERR_SUI20_NOT_MATCH);
            object::delete(id);
            total_amount = total_amount + amount;
        };
        assert!(total_amount > 0, ERR_BALANCE_NOT_ENOUGH);
        vector::destroy_empty(sui20s);

        let sui20 = Sui20 {
            id: object::new(ctx),
            tick,
            amount: total_amount,
        };

        (sui20, total_amount)
    }

    public fun merge_v2(
        global: &mut Global,
        tick: String,
        sui20s: vector<Sui20>,
        needAmount: u64,
        ctx: &mut TxContext,
    ): (Sui20, Sui20, u64, u64) {
        only_allowed_version(global);
        only_not_paused(global);

        assert!(needAmount > 0, ERR_INVALID_AMOUNT);
        assert!(bag::contains(&global.sui20tokens, tick), ERR_SUI20_TICK_NOT_EXISTS);


        let total_amount = 0;
        while (!vector::is_empty(&sui20s)) {
            let sui20 = vector::pop_back(&mut sui20s);
            let Sui20 { id, tick: _tick, amount } = sui20;
            assert!(_tick == tick, ERR_SUI20_NOT_MATCH);
            object::delete(id);
            total_amount = total_amount + amount;
        };
        assert!(total_amount >= needAmount, ERR_BALANCE_NOT_ENOUGH);
        vector::destroy_empty(sui20s);

        let needSui20 = Sui20 {
            id: object::new(ctx),
            tick,
            amount: needAmount,
        };

        let sui20Remaining = Sui20 {
            id: object::new(ctx),
            tick,
            amount: total_amount - needAmount,
        };

        (needSui20, sui20Remaining, total_amount, total_amount - needAmount)
    }

    public fun destroy_zero(sui20: Sui20) {
        let Sui20 { id, tick: _tick, amount } = sui20;
        assert!(amount == 0, ERR_INVALID_AMOUNT);
        object::delete(id);
    }
    /* ------------------------ 4-4 private ------------------------ */
    fun only_not_paused(global: &Global) {
        assert!(!global.is_paused, ERR_ONLY_NOT_PAUSED);
    }

    fun only_allowed_version(global: &Global) {
        assert!(global.current_version <= MAX_ALLOWED_UPGRADE_VERSION, ERR_ONLY_ALLOWED_VERSION);
    }

    fun check_tick(tick: vector<u8>, global: &Global): String {
        let tickName = utf8(tick);
        assert!(vector::length(&tick) == 4, ERR_INVALID_TICK_LENGTH);
        while (!vector::is_empty(&tick)) {
            let c = vector::pop_back(&mut tick);
            // the character of tick can only be a-z, 0-9
            assert!((c >= 97 && c <= 122) || (c >= 48 && c <= 57), ERR_INVALID_TICK);
        };
        assert!(!bag::contains(&global.sui20tokens, tickName), ERR_DUPLICATE_TICK);
        tickName
    }

    /* ------------------------ 4-5 view for frontend ------------------------ */
    public(friend) fun get_sui20_data(obj: &Sui20): (String, u64)  {
        (obj.tick, obj.amount)
    }

    public fun get_mint_data(global: &mut Global, tick: String, ctx: &mut TxContext) {
        let user = sender(ctx);
        assert!(bag::contains(&global.sui20tokens, tick), ERR_SUI20_TICK_NOT_EXISTS);
        let data = bag::borrow_mut<String, Sui20Data>(&mut global.sui20tokens, tick);

        let user_minted_amount = 0;
        let user_hold_amount = 0;
        let user_last_mint_at = 0;
        if (table::contains(&data.user_infos, user)) {
            let info = table::borrow(&data.user_infos, user);
            user_minted_amount = info.minted_amount;
            user_hold_amount = info.hold_amount;
            user_last_mint_at = info.last_mint_at;
        };

        emit(QueryDataEvent{
            tick: data.meta.tick,

            start_at: data.meta.start_at,
            total_cap: data.meta.max,
            limit_per_mint: data.meta.limit,
            decimals: data.meta.decimals,
            mint_fee: data.meta.fee,
            mint_cd: data.mint_cd,
            max_mint_per_user: data.max_mint_per_user,

            // states
            total_minted: data.total_minted,
            remain_supply: data.meta.max - data.total_minted,
            txs: data.txs,

            // user
            user_minted_amount,
            user_hold_amount,
            user_last_mint_at,
        })
    }

    public fun get_users_data(
        global: &mut Global,
        tick: String,
        _ctx: &mut TxContext,
    ) {
        assert!(bag::contains(&global.sui20tokens, tick), ERR_SUI20_TICK_NOT_EXISTS);
        let data = bag::borrow_mut<String, Sui20Data>(&mut global.sui20tokens, tick);

        let minted_amounts = vector[];
        let i = 0;
        let len = vector::length(&data.users);
        while (i < len) {
            let user = *vector::borrow(&data.users, i);
            let minted_amount = if (table::contains(&data.user_infos, user)) {
                let info = table::borrow(&data.user_infos, user);
                info.minted_amount
            } else {
                0
            };
            vector::push_back(&mut minted_amounts, minted_amount);
            i = i + 1;
        };

        emit(QueryUsersEvent {
            users: data.users,
            minted_amounts,
        })
    }

    public fun get_users_data_v2(
        global: &mut Global,
        tick: String,
        users: vector<address>,
        _ctx: &mut TxContext,
    ) {
        assert!(bag::contains(&global.sui20tokens, tick), ERR_SUI20_TICK_NOT_EXISTS);
        let data = bag::borrow_mut<String, Sui20Data>(&mut global.sui20tokens, tick);

        let minted_amounts = vector[];
        let i = 0;
        let len = vector::length(&users);
        while (i < len) {
            let user = *vector::borrow(&users, i);
            let minted_amount = if (table::contains(&data.user_infos, user)) {
                let info = table::borrow(&data.user_infos, user);
                info.minted_amount
            } else {
                0
            };
            vector::push_back(&mut minted_amounts, minted_amount);
            i = i + 1;
        };

        emit(QueryUsersEvent {
            users: data.users,
            minted_amounts,
        })
    }

}
