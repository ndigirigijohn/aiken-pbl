use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use aiken/interval.{Finite, NegativeInfinity, PositiveInfinity}
use cardano/address
use cardano/assets.{add, flatten, from_lovelace, merge, zero}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
  ValidityRange,
}
use mocktail.{
  complete, invalid_before, invalid_hereafter, mock_pub_key_address,
  mock_pub_key_hash, mock_utxo_ref, mocktail_tx,
}

// Datum that stores deadline and administrator information
pub type DeadlineSplitDatum {
  deadline: Int,
  administrator: VerificationKeyHash,
  wallet_a: VerificationKeyHash,
  wallet_b: VerificationKeyHash,
}

// Redeemer to indicate the type of action
pub type DeadlineRedeemer {
  Split
  AdminClaim
}

// Helper function to check if current time is before deadline
fn is_before_deadline(validity_range: ValidityRange, deadline: Int) -> Bool {
  when validity_range.lower_bound.bound_type is {
    Finite(n) -> n < deadline
    NegativeInfinity -> True
    PositiveInfinity -> False
  }
}

// Helper function to check if current time is after deadline
fn is_after_deadline(validity_range: ValidityRange, deadline: Int) -> Bool {
  when validity_range.lower_bound.bound_type is {
    Finite(n) -> n >= deadline
    NegativeInfinity -> False
    PositiveInfinity -> True
  }
}

// Helper function to create tagged output for a wallet
fn create_tagged_output(
  wallet_hash: VerificationKeyHash,
  value,
  tag: OutputReference,
) -> Output {
  Output {
    address: address.from_verification_key(wallet_hash),
    value,
    datum: InlineDatum(tag),
    reference_script: None,
  }
}

validator deadline_payment_splitter {
  spend(
    datum_opt: Option<DeadlineSplitDatum>,
    redeemer: DeadlineRedeemer,
    own_ref: OutputReference,
    tx: Transaction,
  ) {
    expect Some(datum) = datum_opt
    let Transaction { inputs, outputs, extra_signatories, validity_range, .. } =
      tx
    // Find the input UTxO being spent
    expect Some(own_input) =
      list.find(inputs, fn(input) { input.output_reference == own_ref })
    let input_value = own_input.output.value
    // Check deadline status
    let before_deadline = is_before_deadline(validity_range, datum.deadline)
    let after_deadline = is_after_deadline(validity_range, datum.deadline)
    let admin_signed = list.has(extra_signatories, datum.administrator)
    // Handle different redeemer actions
    when redeemer is {
      Split ->
        if !before_deadline {
          False
        } else {
          // Create addresses for the two wallets
          let wallet_a_address = address.from_verification_key(datum.wallet_a)
          let wallet_b_address = address.from_verification_key(datum.wallet_b)
          // Find outputs going to wallet A that are tagged with our input reference
          let wallet_a_outputs =
            list.filter(
              outputs,
              fn(output) {
                when output.datum is {
                  InlineDatum(output_datum) ->
                    if output_datum is OutputReference {
                      and {
                        output.address == wallet_a_address,
                        own_ref == output_datum,
                      }
                    } else {
                      False
                    }
                  _ -> False
                }
              },
            )
          // Find outputs going to wallet B that are tagged with our input reference  
          let wallet_b_outputs =
            list.filter(
              outputs,
              fn(output) {
                when output.datum is {
                  InlineDatum(output_datum) ->
                    if output_datum is OutputReference {
                      and {
                        output.address == wallet_b_address,
                        own_ref == output_datum,
                      }
                    } else {
                      False
                    }
                  _ -> False
                }
              },
            )
          // Sum the values going to each wallet
          let wallet_a_total =
            list.foldl(
              wallet_a_outputs,
              zero,
              fn(output, acc) { merge(output.value, acc) },
            )
          let wallet_b_total =
            list.foldl(
              wallet_b_outputs,
              zero,
              fn(output, acc) { merge(output.value, acc) },
            )
          // Check if the split is equal by comparing flattened asset lists
          let input_assets = flatten(input_value)
          let wallet_a_assets = flatten(wallet_a_total)
          let wallet_b_assets = flatten(wallet_b_total)
          // Verify that each asset is split equally (or as close as possible for odd amounts)
          let is_split_valid =
            list.all(
              input_assets,
              fn(input_asset) {
                let (policy_id, asset_name, total_amount) = input_asset
                // Find corresponding amounts in each wallet's outputs
                let amount_a_opt =
                  list.find(
                    wallet_a_assets,
                    fn(asset) {
                      let (pid, name, _) = asset
                      pid == policy_id && name == asset_name
                    },
                  )
                let amount_b_opt =
                  list.find(
                    wallet_b_assets,
                    fn(asset) {
                      let (pid, name, _) = asset
                      pid == policy_id && name == asset_name
                    },
                  )
                // Both wallets must have this asset type
                when (amount_a_opt, amount_b_opt) is {
                  (Some((_, _, amount_a)), Some((_, _, amount_b))) -> {
                    // Check if amounts are split correctly
                    let half = total_amount / 2
                    let remainder = total_amount % 2
                    or {
                      and {
                        amount_a == half + remainder,
                        amount_b == half,
                      },
                      and {
                        amount_a == half,
                        amount_b == half + remainder,
                      },
                    }
                  }
                  _ -> False
                }
              },
            )
          // Verify that the total distributed equals the input amount
          let total_distributed = merge(wallet_a_total, wallet_b_total)
          let amounts_match = total_distributed == input_value
          // Ensure we have outputs for both wallets
          let has_wallet_a_outputs = !list.is_empty(wallet_a_outputs)
          let has_wallet_b_outputs = !list.is_empty(wallet_b_outputs)
          and {
            is_split_valid?,
            amounts_match?,
            has_wallet_a_outputs?,
            has_wallet_b_outputs?,
          }
        }
      AdminClaim -> and {
          after_deadline?,
          admin_signed?,
        }
    }
  }

  else(_) {
    fail
  }
}

// ===== TESTS =====

// Test: Success case - before deadline, equal split
test test_before_deadline_equal_split_success() {
  let alice_key = mock_pub_key_hash(1)
  let bob_key = mock_pub_key_hash(2)
  let admin_key = mock_pub_key_hash(99)
  let input_ref = mock_utxo_ref(0, 0)
  let datum =
    Some(
      DeadlineSplitDatum {
        deadline: 1767225600000,
        administrator: admin_key,
        wallet_a: alice_key,
        wallet_b: bob_key,
      },
    )
  let redeemer = Split
  // Create input with 10 ADA
  let input_value = from_lovelace(10_000_000)
  let test_input =
    Input {
      output_reference: input_ref,
      output: Output {
        address: mock_pub_key_address(0, None),
        value: input_value,
        datum: NoDatum,
        reference_script: None,
      },
    }
  // Create equal split outputs: 5 ADA each
  let alice_output =
    create_tagged_output(alice_key, from_lovelace(5_000_000), input_ref)
  let bob_output =
    create_tagged_output(bob_key, from_lovelace(5_000_000), input_ref)
  let tx =
    Transaction {
      ..mocktail_tx()
        |> invalid_before(True, 1735689600000)
        |> invalid_hereafter(True, 1767139200000)
        |> complete(),
      inputs: [test_input],
      outputs: [alice_output, bob_output],
      extra_signatories: [],
    }
  deadline_payment_splitter.spend(datum, redeemer, input_ref, tx)
}

// Test: Success case - before deadline, odd amount split
test test_before_deadline_odd_split_success() {
  let alice_key = mock_pub_key_hash(1)
  let bob_key = mock_pub_key_hash(2)
  let admin_key = mock_pub_key_hash(99)
  let input_ref = mock_utxo_ref(0, 0)
  let datum =
    Some(
      DeadlineSplitDatum {
        deadline: 1767225600000,
        administrator: admin_key,
        wallet_a: alice_key,
        wallet_b: bob_key,
      },
    )
  let redeemer = Split
  // Create input with odd amount: 10.000001 ADA
  let input_amount = 10_000_001
  let input_value = from_lovelace(input_amount)
  let test_input =
    Input {
      output_reference: input_ref,
      output: Output {
        address: mock_pub_key_address(0, None),
        value: input_value,
        datum: NoDatum,
        reference_script: None,
      },
    }
  // Calculate split
  let half = input_amount / 2
  let remainder = input_amount % 2
  let alice_amount = half + remainder
  let bob_amount = half
  let alice_output =
    create_tagged_output(alice_key, from_lovelace(alice_amount), input_ref)
  let bob_output =
    create_tagged_output(bob_key, from_lovelace(bob_amount), input_ref)
  let tx =
    Transaction {
      ..mocktail_tx()
        |> invalid_before(True, 1735689600000)
        |> invalid_hereafter(True, 1767139200000)
        |> complete(),
      inputs: [test_input],
      outputs: [alice_output, bob_output],
      extra_signatories: [],
    }
  deadline_payment_splitter.spend(datum, redeemer, input_ref, tx)
}

// Test: Success case - after deadline, admin claims all
test test_after_deadline_admin_claim_success() {
  let alice_key = mock_pub_key_hash(1)
  let bob_key = mock_pub_key_hash(2)
  let admin_key = mock_pub_key_hash(99)
  let input_ref = mock_utxo_ref(0, 0)
  let datum =
    Some(
      DeadlineSplitDatum {
        deadline: 1767225600000,
        administrator: admin_key,
        wallet_a: alice_key,
        wallet_b: bob_key,
      },
    )
  let redeemer = AdminClaim
  // Create input with 10 ADA
  let input_value = from_lovelace(10_000_000)
  let test_input =
    Input {
      output_reference: input_ref,
      output: Output {
        address: mock_pub_key_address(0, None),
        value: input_value,
        datum: NoDatum,
        reference_script: None,
      },
    }
  // Admin gets all the funds
  let admin_output =
    Output {
      address: address.from_verification_key(admin_key),
      value: from_lovelace(10_000_000),
      datum: NoDatum,
      reference_script: None,
    }
  let tx =
    Transaction {
      ..mocktail_tx()
        |> invalid_before(True, 1767312000000)
        |> complete(),
      inputs: [test_input],
      outputs: [admin_output],
      extra_signatories: [admin_key],
    }
  deadline_payment_splitter.spend(datum, redeemer, input_ref, tx)
}

// Test: Failure case - before deadline with unequal split
test test_before_deadline_unequal_split_failure() {
  let alice_key = mock_pub_key_hash(1)
  let bob_key = mock_pub_key_hash(2)
  let admin_key = mock_pub_key_hash(99)
  let input_ref = mock_utxo_ref(0, 0)
  let datum =
    Some(
      DeadlineSplitDatum {
        deadline: 1767225600000,
        administrator: admin_key,
        wallet_a: alice_key,
        wallet_b: bob_key,
      },
    )
  let redeemer = Split
  // Create input with 10 ADA
  let input_value = from_lovelace(10_000_000)
  let test_input =
    Input {
      output_reference: input_ref,
      output: Output {
        address: mock_pub_key_address(0, None),
        value: input_value,
        datum: NoDatum,
        reference_script: None,
      },
    }
  // Create unequal outputs: 7 ADA to Alice, 3 ADA to Bob
  let alice_output =
    create_tagged_output(alice_key, from_lovelace(7_000_000), input_ref)
  let bob_output =
    create_tagged_output(bob_key, from_lovelace(3_000_000), input_ref)
  let tx =
    Transaction {
      ..mocktail_tx()
        |> invalid_before(True, 1735689600000)
        |> invalid_hereafter(True, 1767139200000)
        |> complete(),
      inputs: [test_input],
      outputs: [alice_output, bob_output],
      extra_signatories: [],
    }
  !deadline_payment_splitter.spend(datum, redeemer, input_ref, tx)
}

// Test: Failure case - after deadline, split attempt
test test_after_deadline_split_attempt_failure() {
  let alice_key = mock_pub_key_hash(1)
  let bob_key = mock_pub_key_hash(2)
  let admin_key = mock_pub_key_hash(99)
  let input_ref = mock_utxo_ref(0, 0)
  let datum =
    Some(
      DeadlineSplitDatum {
        deadline: 1767225600000,
        administrator: admin_key,
        wallet_a: alice_key,
        wallet_b: bob_key,
      },
    )
  let redeemer = Split
  let input_value = from_lovelace(10_000_000)
  let test_input =
    Input {
      output_reference: input_ref,
      output: Output {
        address: mock_pub_key_address(0, None),
        value: input_value,
        datum: NoDatum,
        reference_script: None,
      },
    }
  let alice_output =
    create_tagged_output(alice_key, from_lovelace(5_000_000), input_ref)
  let bob_output =
    create_tagged_output(bob_key, from_lovelace(5_000_000), input_ref)
  let tx =
    Transaction {
      ..mocktail_tx()
        |> invalid_before(True, 1767312000000)
        |> complete(),
      inputs: [test_input],
      outputs: [alice_output, bob_output],
      extra_signatories: [],
    }
  !deadline_payment_splitter.spend(datum, redeemer, input_ref, tx)
}

// Test: Failure case - admin claim before deadline
test test_admin_claim_before_deadline_failure() {
  let alice_key = mock_pub_key_hash(1)
  let bob_key = mock_pub_key_hash(2)
  let admin_key = mock_pub_key_hash(99)
  let input_ref = mock_utxo_ref(0, 0)
  let datum =
    Some(
      DeadlineSplitDatum {
        deadline: 1767225600000,
        administrator: admin_key,
        wallet_a: alice_key,
        wallet_b: bob_key,
      },
    )
  let redeemer = AdminClaim
  let input_value = from_lovelace(10_000_000)
  let test_input =
    Input {
      output_reference: input_ref,
      output: Output {
        address: mock_pub_key_address(0, None),
        value: input_value,
        datum: NoDatum,
        reference_script: None,
      },
    }
  let admin_output =
    Output {
      address: address.from_verification_key(admin_key),
      value: from_lovelace(10_000_000),
      datum: NoDatum,
      reference_script: None,
    }
  let tx =
    Transaction {
      ..mocktail_tx()
        |> invalid_before(True, 1735689600000)
        |> invalid_hereafter(True, 1767139200000)
        |> complete(),
      inputs: [test_input],
      outputs: [admin_output],
      extra_signatories: [admin_key],
    }
  !deadline_payment_splitter.spend(datum, redeemer, input_ref, tx)
}

// Test: Failure case - admin claim after deadline without signature
test test_admin_claim_no_signature_failure() {
  let alice_key = mock_pub_key_hash(1)
  let bob_key = mock_pub_key_hash(2)
  let admin_key = mock_pub_key_hash(99)
  let input_ref = mock_utxo_ref(0, 0)
  let datum =
    Some(
      DeadlineSplitDatum {
        deadline: 1767225600000,
        administrator: admin_key,
        wallet_a: alice_key,
        wallet_b: bob_key,
      },
    )
  let redeemer = AdminClaim
  let input_value = from_lovelace(10_000_000)
  let test_input =
    Input {
      output_reference: input_ref,
      output: Output {
        address: mock_pub_key_address(0, None),
        value: input_value,
        datum: NoDatum,
        reference_script: None,
      },
    }
  let admin_output =
    Output {
      address: address.from_verification_key(admin_key),
      value: from_lovelace(10_000_000),
      datum: NoDatum,
      reference_script: None,
    }
  let tx =
    Transaction {
      ..mocktail_tx()
        |> invalid_before(True, 1767312000000)
        |> complete(),
      inputs: [test_input],
      outputs: [admin_output],
      extra_signatories: [],
    }
  !deadline_payment_splitter.spend(datum, redeemer, input_ref, tx)
}

// Test: Success case - mixed assets split before deadline
test test_mixed_assets_split_success() {
  let alice_key = mock_pub_key_hash(1)
  let bob_key = mock_pub_key_hash(2)
  let admin_key = mock_pub_key_hash(99)
  let input_ref = mock_utxo_ref(0, 0)
  let datum =
    Some(
      DeadlineSplitDatum {
        deadline: 1767225600000,
        administrator: admin_key,
        wallet_a: alice_key,
        wallet_b: bob_key,
      },
    )
  let redeemer = Split
  let policy_id = #"00000000000000000000000000000000000000000000000000000000"
  let token_name = #"544f4b454e"
  let input_value = from_lovelace(10_000_000) |> add(policy_id, token_name, 100)
  let test_input =
    Input {
      output_reference: input_ref,
      output: Output {
        address: mock_pub_key_address(0, None),
        value: input_value,
        datum: NoDatum,
        reference_script: None,
      },
    }
  let alice_value = from_lovelace(5_000_000) |> add(policy_id, token_name, 50)
  let bob_value = from_lovelace(5_000_000) |> add(policy_id, token_name, 50)
  let alice_output = create_tagged_output(alice_key, alice_value, input_ref)
  let bob_output = create_tagged_output(bob_key, bob_value, input_ref)
  let tx =
    Transaction {
      ..mocktail_tx()
        |> invalid_before(True, 1735689600000)
        |> invalid_hereafter(True, 1767139200000)
        |> complete(),
      inputs: [test_input],
      outputs: [alice_output, bob_output],
      extra_signatories: [],
    }
  deadline_payment_splitter.spend(datum, redeemer, input_ref, tx)
}
