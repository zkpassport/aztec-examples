mod test;

use aztec::macros::aztec;

/// Fortuna's prediction markets, open only to traders who hold an `AgeGate`'s 18+ badge.
#[aztec]
pub contract FortunaMarket {
    use crate::order_key;
    use age_gate_contract::AgeGate;
    use aztec::{
        macros::{functions::{external, initializer, only_self, view}, storage::storage},
        protocol::address::AztecAddress,
        state_vars::{Map, PublicImmutable, PublicMutable},
    };

    #[storage]
    struct Storage<Context> {
        age_gate: PublicImmutable<AztecAddress, Context>,
        // Orders per market and side. Public, but they don't name the trader.
        orders: Map<Field, PublicMutable<u64, Context>, Context>,
    }

    /// `age_gate` is the `AgeGate` whose badge a trader must hold.
    #[external("public")]
    #[initializer]
    fn constructor(age_gate: AztecAddress) {
        self.storage.age_gate.initialize(age_gate);
    }

    /// Places the sender's order on `market`, on its yes side or its no side. Fails with "no badge"
    /// unless the sender holds the age gate's badge, which the sender's wallet reads from its own
    /// notes.
    #[external("private")]
    fn place_order(market: Field, yes: bool) {
        let trader = self.msg_sender();
        self.call(AgeGate::at(self.storage.age_gate.read()).assert_has_badge(trader));
        self.enqueue_self._count_order(market, yes);
    }

    #[external("public")]
    #[only_self]
    fn _count_order(market: Field, yes: bool) {
        let side = self.storage.orders.at(order_key(market, yes));
        side.write(side.read() + 1);
    }

    /// The number of orders placed on `market`'s yes side or no side.
    #[external("public")]
    #[view]
    fn orders(market: Field, yes: bool) -> u64 {
        self.storage.orders.at(order_key(market, yes)).read()
    }
}

fn order_key(market: Field, yes: bool) -> Field {
    market * 2 + (yes as Field)
}
