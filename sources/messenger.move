// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Implementation a cross-chain messaging system for Axelar.
///
/// This code is based on the following:
///
/// - When message is sent to Sui, it targets an object and not a module;
/// - To support cross-chain messaging, a Channel object has to be created;
/// - Channel can be either owned or shared but not frozen;
/// - Module developer on the Sui side will have to implement a system to support messaging;
/// - Checks for uniqueness of messages should be done through `Channel`s to avoid big data storage;
///
/// I. Sending messages
///
/// A message is sent through the `send` function, a Channel is supplied to determine the source -> ID.
/// Event is then emitted and Axelar network can operate
///
/// II. Receiving messages
///
/// Message bytes and signatures are passed into `create` function to generate a Message object.
///  - Signatures are checked against the known set of validators.
///  - Message bytes are parsed to determine: source, destination_chain, payload and target_id
///  - `target_id` points to a `Channel` object
///
/// Once created, `Message` needs to be consumed. And the only way to do it is by calling
/// `consume_message` function and pass a correct `Channel` instance alongside the `Message`.
///  - Message is checked for uniqueness (for this channel)
///  - Message is checked to match the `Channel`.id
///
module axelar::messenger {
    use sui::object::{Self, UID};
    use sui::vec_set::{Self, VecSet};
    use sui::tx_context::{TxContext};
    use sui::vec_map::{Self, VecMap};
    use sui::ecdsa::{Self};

    use std::vector as vec;

    // Temp use a local version of BCS
    use sui::bcs;

    /// For when trying to consume the wrong object.
    const EWrongDestination: u64 = 0;

    /// For when message signatures failed verification.
    const ESignatureInvalid: u64 = 1;

    /// For when message has already been processed and submitted twice.
    const EDuplicateMessage: u64 = 2;

    /// For when message chainId is not SUI.
    const EInvalidChain: u64 = 3;

    /// For when number of commands does not match number of command ids.
    const EInvalidCommands: u64 = 4;

    /// For when operators have changed, and proof is no longer valid.
    const EInvalidOperators: u64 = 5;

    /// For when number of signatures for the message is below the threshold.
    const ELowSignaturesWeight: u64 = 6;

    /// Used for a check in `validate_proof` function.
    const OLD_KEY_RETENTION: u64 = 16;

    // These are currently supported
    const SELECTOR_APPROVE_CONTRACT_CALL: vector<u8> = b"approveContractCall";
    const SELECTOR_TRANSFER_OPERATORSHIP: vector<u8> = b"transferOperatorship";

    /// Mocking this for now until actual implementation of validator management.
    /// Nevertheless it will be a shared / frozen object accessible to everyone
    /// on the network.
    ///
    /// Perhaps, its implementation should be moved to a different module which
    /// will implement messenger interface for the `Validators` object.
    struct Validators has key {
        id: UID,
        epoch: u64,
        epoch_for_hash: VecMap<vector<u8>, u64>
    }

    /// Generic target for the messaging system.
    ///
    /// This struct is required on the Sui side to be the destination for the
    /// messages sent from other chains. Even though it has a UID field, it does
    /// not have a `key` ability to force wrapping.
    ///
    /// Notes:
    ///
    /// - Does not have key to prevent 99% of the mistakes related to access management.
    /// Also prevents arbitrary Message destruction if the object is shared. Lastly,
    /// when shared, `Channel` cannot be destroyed, and its contents will remain locked
    /// forever.
    ///
    /// - Allows asset or capability-locking inside. Some applications might
    /// authorize admin actions through the bridge (eg by locking some `AdminCap`
    /// inside and getting a `&mut AdminCap` in the `consume_message`);
    ///
    /// - Can be destroyed freely as the `UID` is guaranteed to be unique across
    /// the system. Destroying a channel would mean the end of the Channel cycle
    /// and all further messages will have to target a new Channel if there is one.
    ///
    /// - Does not contain direct link to the state in Sui, as some functions
    /// might not take any specific data (eg allow users to create new objects).
    /// If specific object on Sui is targeted by this `Channel`, its reference
    /// should be implemented using the `data` field.
    ///
    /// - The funniest and extremely simple implementation would be a `Channel<ID>`
    /// since it actually contains the data required to point at the object in Sui.
    struct Channel<T: store> has store {
        /// Unique ID of the target object which allows message targeting
        /// by comparing against `id_bytes`.
        id: UID,
        /// Messages processed by this object. To make system less
        /// centralized, and spread the storage + io costs across multiple
        /// destinations, we can track every `Channel`'s messages.
        messages: VecSet<vector<u8>>,
        /// Additional field to optionally use as metadata for the Channel
        /// object improving identification and uniqueness of data.
        /// Can store any struct that has `store` ability (including other
        /// objects - eg Capabilities).
        data: T
    }

    /// Message object which can consumed only by a `Channel` object.
    /// Does not require additional generic field to operate as linking
    /// by `id_bytes` is more than enough.
    ///
    /// Consider naming this `axelar::messaging::CallApproval`.
    struct Message has key, store {
        id: UID,
        /// ID of the message, guaranteed to be unique by Axelar.
        msg_id: vector<u8>,
        /// The target Channel's UID.
        target_id: address,
        /// Name of the chain where this message came from.
        source_chain: vector<u8>,
        /// Address of the source chain (vector used for compatibility).
        /// UTF8 / ASCII encoded string (for 0x0... eth address gonna be 42 bytes with 0x)
        source_address: vector<u8>,
        /// Hash of the full payload (including source_* fields).
        payload_hash: vector<u8>,
        /// The rest of the payload to be used by the application.
        payload: vector<u8>,
    }

    /// Emitted when a new message is sent from the SUI network.
    struct MessageSent has copy, drop {
        source: vector<u8>,
        destination: vector<u8>,
        destination_address: vector<u8>,
        payload: vector<u8>,
    }

    /// Create new `Channel<T>` object. Anyone can create their own `Channel` to target
    /// from the outside and there's no limitation to the data stored inside it.
    ///
    /// `copy` ability is required to disallow asset locking inside the `Channel`.
    public fun create_channel<T: store>(t: T, ctx: &mut TxContext): Channel<T> {
        Channel {
            id: object::new(ctx),
            messages: vec_set::empty(),
            data: t
        }
    }

    /// Destroy a `Channel<T>` releasing the T. Not constrained and can be performed
    /// by any party as long as they own a Channel.
    public fun destroy_channel<T: store>(self: Channel<T>): T {
        let Channel { id, messages: _, data } = self;
        object::delete(id);
        data
    }

    /// Main entrypoint for the messaging protocol.
    /// Processes the data and the signatures generating a vector of
    /// `Message` objects.
    ///
    /// Aborts with multiple error codes, ignores messages which are not
    /// supported by the current implementation of the protocol.
    ///
    /// Input data must be serialized with BCS (see specification here: https://github.com/diem/bcs).
    public fun create_messages(
        validators: &mut Validators, // shared Validators
        input: vector<u8>,
        ctx: &mut TxContext
    ): vector<Message> {
        let bytes = bcs::new(input);

        // Split input into:
        // data: vector<u8> (BCS bytes)
        // proof: vector<u8> (BCS bytes)
        let (data, proof) = (
            bcs::peel_vec_u8(&mut bytes),
            bcs::peel_vec_u8(&mut bytes)
        );

        // [DEBUG] print out lengths to prove that we got `data` and `proof` right
        std::debug::print(&vec::length(&data));
        std::debug::print(&vec::length(&proof));

        // TODO: Add a sui-specific prefix for the hash (eg "Sui Signed message");
        let message_hash = ecdsa::keccak256(&data);
        let _allow_operatorship_transfer = validate_proof(validators, message_hash, proof);

        // Treat `data` as BCS bytes.
        let data_bcs = bcs::new(data);

        // Split data into:
        // chain_id: u64,
        // command_ids: vector<vector<u8>> (vector<string>)
        // commands: vector<vector<u8>> (vector<string>)
        // params: vector<vector<u8>> (vector<string>)
        let (_chain_id, command_ids, commands, params) = (
            bcs::peel_u64(&mut data_bcs),
            bcs::peel_vec_vec_u8(&mut data_bcs),
            bcs::peel_vec_vec_u8(&mut data_bcs),
            bcs::peel_vec_vec_u8(&mut data_bcs)
        );

        std::debug::print(&_chain_id);

        // ... figure out whether it has to be a string ...
        // ignore me, I'm not eth
        // assert!(chain_id == 1, EInvalidChain);

        let (i, commands_len, messages) = (0, vec::length(&commands), vec::empty());

        std::debug::print(&commands_len);

        // make sure number of commands passed matches command IDs
        assert!(vec::length(&command_ids) == commands_len, EInvalidCommands);

        while (i < commands_len) {
            let msg_id = *vec::borrow(&command_ids, i);
            let cmd_selector = vec::borrow(&commands, i);
            let payload = bcs::new(*vec::borrow(&params, i));

            i = i + 1;

            // Build a `Message` object from the `params[i]`. BCS serializes data
            // in order, so field reads have to be done carefully and in order!
            if (cmd_selector == &SELECTOR_APPROVE_CONTRACT_CALL) {
                vec::push_back(&mut messages, Message {
                    id: object::new(ctx),
                    msg_id,

                    source_chain: bcs::peel_vec_u8(&mut payload),
                    source_address: bcs::peel_vec_u8(&mut payload),
                    target_id: bcs::peel_address(&mut payload),
                    payload_hash: bcs::peel_vec_u8(&mut payload),

                    payload: bcs::into_remainder_bytes(payload)
                });
                continue
            } else if (cmd_selector == &SELECTOR_TRANSFER_OPERATORSHIP) {
                // TODO: please, don't forget about me, champ
                // filter msg_id in Validators

                // CALL BUILT_IN_STUFF;
                continue
            } else {
                continue
            };

            // TBD once we get to token transfers.
            // else if (cmd_selector == &SELECTOR_APPROVE_CONTRACT_CALL_WITH_MINT) {
            //     continue
            // };
        };

        messages
    }

    /// [DEPRECATED]
    ///
    /// Spawn a message from the passed data and signatures. Data is processed and
    /// used to construct a `Message` struct, and the signatures are checked to be
    /// of current validators from the validator set.
    public fun create_message() { /* Consider removing this function */ }

    /// By using &mut here we make sure that the object is not in the freeze
    /// state and the owner has full access to the target.
    ///
    /// Most common scenario would be to target a shared object, however this
    /// messaging system allows sending private messages which can be consumed
    /// by single-owner targets.
    ///
    /// For Capability-locking, a mutable reference to the `Channel.data` field is
    /// returned; the rest are the fields of the `Message`.
    public fun consume_message<T: store>(
        t: &mut Channel<T>, m: Message
    ): (&mut T, vector<u8>, vector<u8>, vector<u8>, vector<u8>) {
        let Message {
            id,
            msg_id,
            target_id,
            source_chain,
            source_address,
            payload_hash,
            payload
        } = m;

        assert!(!vec_set::contains(&t.messages, &msg_id), EDuplicateMessage);
        assert!(target_id == object::uid_to_address(&t.id), EWrongDestination);
        object::delete(id);

        (
            &mut t.data,
            source_chain,
            source_address,
            payload_hash,
            payload
        )
    }

    #[test_only]
    /// Test-only function that replaces `target_id` with the channel ID.
    public fun consume_message_ignore_uid<T: store>(
        t: &mut Channel<T>, m: Message
    ): (&mut T, vector<u8>, vector<u8>, vector<u8>, vector<u8>) {
        let bytes = bcs::new(object::uid_to_bytes(&t.id));
        m.target_id = bcs::peel_address(&mut bytes);
        consume_message(t, m)
    }

    /// Send a message to another chain. Supply the event data and the
    /// destination chain.
    ///
    /// Event data is collected from the Channel (eg ID of the source
    /// and source_chain is a constant).
    public fun send_message<T: store>(
        t: &mut Channel<T>,
        destination: vector<u8>,
        destination_address: vector<u8>,
        payload: vector<u8>
    ) {
        sui::event::emit(MessageSent {
            source: object::uid_to_bytes(&t.id),
            destination,
            destination_address,
            payload,
        })
    }


    /// Implementation of the `AxelarAuthWeighted.validateProof`.
    /// Does proof validation, fails when proof is invalid or if weight
    /// threshold is not reached.
    fun validate_proof(
        validators: &mut Validators,
        message_hash: vector<u8>,
        proof: vector<u8>
    ): bool {
        // Turn everything into bcs bytes and split data.
        let proof = bcs::new(proof);
        let (operators, weights, threshold, signatures) = (
            bcs::peel_vec_vec_u8(&mut proof),
            bcs::peel_vec_u64(&mut proof),
            bcs::peel_u64(&mut proof),
            bcs::peel_vec_vec_u8(&mut proof)
        );

        std::debug::print(&10000);
        std::debug::print(&weights);

        // TODO: revisit this line and change the way operators hash is generated.
        let operators_length = vec::length(&operators);
        let _operators_epoch = *vec_map::get(&validators.epoch_for_hash, &operators_hash(&operators));
        let _epoch = validators.epoch;

        // TODO: unblock once there's enough signatures for testing.
        // assert!(operators_epoch != 0 && epoch - operators_epoch < OLD_KEY_RETENTION, EInvalidOperators);

        let (i, weight, operator_index) = (0, 0, 0);
        let total_signatures = vec::length(&signatures);

        // [DEBUG] checking number of signatures
        std::debug::print(&true);
        std::debug::print(&total_signatures);

        while (i < total_signatures) {
            let signed_by: vector<u8> = ecdsa::ecrecover(vec::borrow(&signatures, i), &message_hash);
            while (operator_index < operators_length && &signed_by != vec::borrow(&operators, operator_index)) {
                operator_index = operator_index + 1;
            };

            // assert!(operator_index == operators_length, 0); // EMalformedSigners

            // [DEBUG] print out the public key of the signer
            std::debug::print(&signed_by);
            std::debug::print(&operator_index);

            weight = weight + *vec::borrow(&weights, operator_index);
            if (weight >= threshold) { return true };
            operator_index = operator_index + 1;
        };

        abort ELowSignaturesWeight
    }

    // Test message for the `test_execute` test.
    // Generated via the `presets` script.
    #[test_only]
    const MESSAGE: vector<u8> = x"a40101000000000000000209726f6775655f6f6e650a6178656c61725f74776f0210646f5f736f6d657468696e675f66756e0b646f5f69745f616761696e02310345544803307830000000000000000000000000000000000000000000000000000000000000040000000005000000000034064158454c4152033078310000000000000000000000000000000000000000000000000000000000000400000000050000000000770121037286a4f1177bea06c8e15cf6ec3df0b7747a01ac2329ca2999dfd74eff5990280164000000000000000a00000000000000014160cd31d8a9fb343015cf2e88ff42cd349430cca8853032c38b2054e280342fab237bcddc0b799161fce695e2768fc3671cc767ec23815cf8c3f3b73528383fc900";

    #[test] fun test_ecrecover() {
        let message = x"01000000000000000209726f6775655f6f6e650a6178656c61725f74776f0210646f5f736f6d657468696e675f66756e0b646f5f69745f616761696e02310345544803307830000000000000000000000000000000000000000000000000000000000000040000000005000000000034064158454c4152033078310000000000000000000000000000000000000000000000000000000000000400000000050000000000";
        let signature = x"60cd31d8a9fb343015cf2e88ff42cd349430cca8853032c38b2054e280342fab237bcddc0b799161fce695e2768fc3671cc767ec23815cf8c3f3b73528383fc900";
        let pub_key = ecdsa::ecrecover(&signature, &ecdsa::keccak256(&message));

        std::debug::print(&pub_key);
    }

    #[test] fun test_execute() {
        use sui::test_scenario::{Self as ts, ctx};

        // public keys of `operators`
        let epoch = 1;
        let operators = vector[
            x"037286a4f1177bea06c8e15cf6ec3df0b7747a01ac2329ca2999dfd74eff599028"
        ];

        let epoch_for_hash = vec_map::empty();
        vec_map::insert(&mut epoch_for_hash, operators_hash(&operators), epoch);

        let test = ts::begin(@0x0);

        // create validators for testing
        let validators = Validators {
            id: object::new(ctx(&mut test)),
            epoch_for_hash,
            epoch,
        };

        let messages = create_messages(&mut validators, MESSAGE, ctx(&mut test));

        // validator cleanup
        let Validators { id, epoch: _, epoch_for_hash: _ } = validators;

        delete_messages(messages);
        object::delete(id);
        ts::end(test);
    }

    #[test_only]
    /// Handy method for burning `vector<Message>` returned by the `execute` function.
    fun delete_messages(msgs: vector<Message>) {
        while (vec::length(&msgs) > 0) {
            let Message {
                id,
                msg_id: _,
                target_id: _,
                source_chain: _,
                source_address: _,
                payload_hash: _,
                payload: _
            } = vec::pop_back(&mut msgs);
            object::delete(id);
        };
        vec::destroy_empty(msgs);
    }

    /// Compute operators hash from the list of `operators` (public keys).
    /// This hash is used in `Validators.epoch_for_hash`.
    ///
    /// TODO: also take weights and thresholds (include into hashing).
    fun operators_hash(operators: &vector<vector<u8>>): vector<u8> {
        ecdsa::keccak256(&bcs::to_bytes(operators))
    }
}
