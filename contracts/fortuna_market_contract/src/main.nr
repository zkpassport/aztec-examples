mod test;

use aztec::macros::aztec;

/// Fortuna's prediction markets, open only to traders who hold a credential of one
/// `ZKPassportCredentials` policy, such as 18+.
#[aztec]
pub contract FortunaMarket {
    use crate::order_key;
    use aztec::{
        macros::{functions::{external, initializer, only_self, view}, storage::storage},
        protocol::{address::AztecAddress, traits::Packable},
        state_vars::{Map, PublicImmutable, PublicMutable},
    };
    use zkpassport_credentials_contract::ZKPassportCredentials;

    /// The credential a trader must hold: its contract and its policy
    #[derive(Eq, Packable)]
    struct Gate {
        credentials: AztecAddress,
        policy_id: Field,
    }

    #[storage]
    struct Storage<Context> {
        gate: PublicImmutable<Gate, Context>,
        // Orders per market and side. Public, but they don't name the trader.
        orders: Map<Field, PublicMutable<u64, Context>, Context>,
    }

    /// A trader must hold a credential of `policy_id` on the `ZKPassportCredentials` contract
    /// `credentials`.
    #[external("public")]
    #[initializer]
    fn constructor(credentials: AztecAddress, policy_id: Field) {
        self.storage.gate.initialize(Gate { credentials, policy_id });
    }

    /// Places the sender's order on `market`, on its yes side or its no side. Fails with "no
    /// credential" unless the sender holds the policy's credential, which the sender's wallet reads
    /// from its own notes.
    #[external("private")]
    fn place_order(market: Field, yes: bool) {
        let trader = self.msg_sender();
        let gate = self.storage.gate.read();
        self.call(ZKPassportCredentials::at(gate.credentials).assert_has_credential(
            trader,
            gate.policy_id,
        ));
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
