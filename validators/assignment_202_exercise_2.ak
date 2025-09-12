use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use cardano/address
use cardano/assets.{add, flatten, from_lovelace, merge, zero}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
}
use mocktail.{
  complete, mock_pub_key_address, mock_pub_key_hash, mock_utxo_ref, mocktail_tx,
}

// Redeemer that specifies the two wallets to split payment between
pub type SplitRedeemer {
  wallet_a: VerificationKeyHash,
  wallet_b: VerificationKeyHash,
}

validator payment_splitter {
  spend(
    _datum: Option<Data>,
    redeemer: SplitRedeemer,
    own_ref: OutputReference,
    tx: Transaction,
  ) {
    let Transaction { inputs, outputs, .. } = tx
    // Find the input UTxO being spent
    expect Some(own_input) =
      list.find(inputs, fn(input) { input.output_reference == own_ref })
    let input_value = own_input.output.value
    // Create addresses for the two wallets
    let wallet_a_address = address.from_verification_key(redeemer.wallet_a)
    let wallet_b_address = address.from_verification_key(redeemer.wallet_b)
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
          // Find corresponding amounts in each wallet's outputs (using safe lookup)
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
              // For even amounts: each wallet gets exactly half
              // For odd amounts: one wallet gets (n+1)/2, other gets n/2
              let half = total_amount / 2
              let remainder = total_amount % 2
              trace @"VALIDATOR_total_amount": total_amount
              trace @"VALIDATOR_half": half
              trace @"VALIDATOR_remainder": remainder
              trace @"VALIDATOR_amount_a": amount_a
              trace @"VALIDATOR_amount_b": amount_b
              trace @"VALIDATOR_half_plus_remainder": half + remainder
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

  else(_) {
    fail
  }
}

// Helper function to create tagged output for a wallet
fn create_tagged_output(
  wallet_hash: VerificationKeyHash,
  value,
  tag: OutputReference,
) -> Output {
  trace @"HELPER_creating_output_for_wallet": wallet_hash
  trace @"HELPER_output_value_assets": flatten(value)
  Output {
    address: address.from_verification_key(wallet_hash),
    value,
    datum: InlineDatum(tag),
    reference_script: None,
  }
}

// Test: Success case - even amount split (10 ADA split into 5 ADA each)
test test_even_split_success() {
  let alice_key = mock_pub_key_hash(1)
  let bob_key = mock_pub_key_hash(2)
  let redeemer = SplitRedeemer { wallet_a: alice_key, wallet_b: bob_key }
  let input_ref = mock_utxo_ref(0, 0)
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
  // Create outputs: 5 ADA to Alice, 5 ADA to Bob (both tagged)
  let alice_output =
    create_tagged_output(alice_key, from_lovelace(5_000_000), input_ref)
  let bob_output =
    create_tagged_output(bob_key, from_lovelace(5_000_000), input_ref)
  let tx =
    Transaction {
      ..mocktail_tx() |> complete(),
      inputs: [test_input],
      outputs: [alice_output, bob_output],
      extra_signatories: [],
    }
  payment_splitter.spend(None, redeemer, input_ref, tx)
}

// Test: Success case - odd amount split (10.000001 ADA = 10,000,001 lovelaces)
test test_odd_split_success() {
  let alice_key = mock_pub_key_hash(1)
  let bob_key = mock_pub_key_hash(2)
  let redeemer = SplitRedeemer { wallet_a: alice_key, wallet_b: bob_key }
  let input_ref = mock_utxo_ref(0, 0)
  // Use 10,000,001 lovelaces (10.000001 ADA) - this is truly odd
  let input_amount = 10_000_001
  trace @"TEST_input_amount": input_amount
  let input_value = from_lovelace(input_amount)
  trace @"TEST_input_flattened": flatten(input_value)
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
  // Calculate the split: 10,000,001 / 2 = 5,000,000 remainder 1
  let half = input_amount / 2
  // 5,000,000
  let remainder = input_amount % 2
  // 1
  let alice_amount = half + remainder
  // 5,000,001
  let bob_amount = half
  // 5,000,000
  trace @"TEST_half": half
  trace @"TEST_remainder": remainder
  trace @"TEST_alice_amount": alice_amount
  trace @"TEST_bob_amount": bob_amount
  // Create outputs with calculated amounts
  let alice_output =
    create_tagged_output(alice_key, from_lovelace(alice_amount), input_ref)
  let bob_output =
    create_tagged_output(bob_key, from_lovelace(bob_amount), input_ref)
  let tx =
    Transaction {
      ..mocktail_tx() |> complete(),
      inputs: [test_input],
      outputs: [alice_output, bob_output],
      extra_signatories: [],
    }
  payment_splitter.spend(None, redeemer, input_ref, tx)
}

// Test: Failure case - unequal split
test test_unequal_split_failure() {
  let alice_key = mock_pub_key_hash(1)
  let bob_key = mock_pub_key_hash(2)
  let redeemer = SplitRedeemer { wallet_a: alice_key, wallet_b: bob_key }
  let input_ref = mock_utxo_ref(0, 0)
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
      ..mocktail_tx() |> complete(),
      inputs: [test_input],
      outputs: [alice_output, bob_output],
      extra_signatories: [],
    }
  // This should fail
  !payment_splitter.spend(None, redeemer, input_ref, tx)
}

// Test: Failure case - missing wallet output
test test_missing_wallet_failure() {
  let alice_key = mock_pub_key_hash(1)
  let bob_key = mock_pub_key_hash(2)
  let redeemer = SplitRedeemer { wallet_a: alice_key, wallet_b: bob_key }
  let input_ref = mock_utxo_ref(0, 0)
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
  // Create output only for Alice, missing Bob's output
  let alice_output =
    create_tagged_output(alice_key, from_lovelace(10_000_000), input_ref)
  let tx =
    Transaction {
      ..mocktail_tx() |> complete(),
      inputs: [test_input],
      outputs: [alice_output],
      extra_signatories: [],
    }
  // This should fail because Bob has no output
  !payment_splitter.spend(None, redeemer, input_ref, tx)
}

// Test: Failure case - wrong total amount
test test_wrong_total_failure() {
  let alice_key = mock_pub_key_hash(1)
  let bob_key = mock_pub_key_hash(2)
  let redeemer = SplitRedeemer { wallet_a: alice_key, wallet_b: bob_key }
  let input_ref = mock_utxo_ref(0, 0)
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
  // Create outputs that total more than input: 6 ADA to Alice, 6 ADA to Bob = 12 ADA
  let alice_output =
    create_tagged_output(alice_key, from_lovelace(6_000_000), input_ref)
  let bob_output =
    create_tagged_output(bob_key, from_lovelace(6_000_000), input_ref)
  let tx =
    Transaction {
      ..mocktail_tx() |> complete(),
      inputs: [test_input],
      outputs: [alice_output, bob_output],
      extra_signatories: [],
    }
  // This should fail because total output > input
  !payment_splitter.spend(None, redeemer, input_ref, tx)
}

// Test: Success case with mixed assets (ADA + native tokens)
test test_mixed_assets_success() {
  let alice_key = mock_pub_key_hash(1)
  let bob_key = mock_pub_key_hash(2)
  let redeemer = SplitRedeemer { wallet_a: alice_key, wallet_b: bob_key }
  let input_ref = mock_utxo_ref(0, 0)
  // Create input with ADA + some custom tokens
  let policy_id = #"00000000000000000000000000000000000000000000000000000000"
  let token_name = #"544f4b454e"
  // "TOKEN" in hex
  let input_value =
    from_lovelace(10_000_000)
      |> add(policy_id, token_name, 100)
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
  // Split: 10M lovelace -> 5M each, 100 tokens -> 50 each
  let alice_value =
    from_lovelace(5_000_000)
      |> add(policy_id, token_name, 50)
  let bob_value =
    from_lovelace(5_000_000)
      |> add(policy_id, token_name, 50)
  let alice_output = create_tagged_output(alice_key, alice_value, input_ref)
  let bob_output = create_tagged_output(bob_key, bob_value, input_ref)
  let tx =
    Transaction {
      ..mocktail_tx() |> complete(),
      inputs: [test_input],
      outputs: [alice_output, bob_output],
      extra_signatories: [],
    }
  payment_splitter.spend(None, redeemer, input_ref, tx)
}
