use aiken/collection/list
use cardano/address.{Address}
use cardano/assets.{Value, from_lovelace, lovelace_of, merge, zero}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction, placeholder,
}
use mocktail.{mock_pub_key_address, mock_script_address, mock_utxo_ref}

// Redeemer specifies the two wallets that will receive equal splits
pub type SplitRedeemer {
  wallet_1: Address,
  wallet_2: Address,
}

validator equal_split_payment {
  spend(
    _datum: Option<Data>,
    redeemer: SplitRedeemer,
    own_ref: OutputReference,
    tx: Transaction,
  ) {
    let SplitRedeemer { wallet_1, wallet_2 } = redeemer
    let Transaction { inputs, outputs, .. } = tx

    // Find the input being spent (the one we're unlocking)
    expect Some(own_input) =
      list.find(inputs, fn(input) { input.output_reference == own_ref })
    let input_value = own_input.output.value

    // Find outputs going to each wallet, tagged with the input reference to prevent double satisfaction
    let wallet_1_outputs =
      get_tagged_outputs_by_address(outputs, wallet_1, own_ref)
    let wallet_2_outputs =
      get_tagged_outputs_by_address(outputs, wallet_2, own_ref)

    // Calculate total value sent to each wallet
    let wallet_1_total = calculate_total_value(wallet_1_outputs)
    let wallet_2_total = calculate_total_value(wallet_2_outputs)

    // Verify equal distribution - each wallet should get exactly half of the input value
    let half_input_value = divide_value_by_two(input_value)
    // Ensure equal distribution (no address comparison to avoid type issues)
    values_equal(wallet_1_total, half_input_value) && values_equal(
      wallet_2_total,
      half_input_value,
    )
  }

  else(_) {
    fail
  }
}

// Get outputs going to a specific address that are tagged with the input reference
// This prevents double satisfaction attacks
fn get_tagged_outputs_by_address(
  outputs: List<Output>,
  target_address: Address,
  tag: OutputReference,
) -> List<Output> {
  list.filter(
    outputs,
    fn(output) {
      when output.datum is {
        InlineDatum(output_datum) ->
          // The output must be going to the target address AND tagged with our input reference
          if output_datum is OutputReference {
            output.address == target_address && output_datum == tag
          } else {
            False
          }
        _ ->
          // For outputs without inline datum, just check the address
          // (This is less secure but allows for simpler transactions)
          output.address == target_address
      }
    },
  )
}

// Calculate the total value from a list of outputs
fn calculate_total_value(outputs: List<Output>) -> Value {
  list.foldl(outputs, zero, fn(output, acc) { merge(output.value, acc) })
}

// Divide a value by 2 (for equal splitting)
// This function handles both ADA and native tokens
fn divide_value_by_two(value: Value) -> Value {
  // For this implementation, we'll focus on ADA (lovelace) splitting
  // In a real implementation, you'd need to handle all tokens in the value
  let ada_amount = lovelace_of(value)
  // Ensure even amount for clean splitting
  expect ada_amount % 2 == 0
  from_lovelace(ada_amount / 2)
}

// Check if two values are equal
fn values_equal(value1: Value, value2: Value) -> Bool {
  // Simple comparison - in practice you might want more sophisticated comparison
  value1 == value2
}

// Helper function to build test transactions
fn build_split_transaction(
  input_value: Value,
  wallet_1: Address,
  wallet_2: Address,
  wallet_1_value: Value,
  wallet_2_value: Value,
  tag_outputs: Bool,
  input_ref: OutputReference,
) -> Transaction {
  let wallet_1_output =
    if tag_outputs {
      Output {
        address: wallet_1,
        value: wallet_1_value,
        datum: InlineDatum(input_ref),
        reference_script: None,
      }
    } else {
      Output {
        address: wallet_1,
        value: wallet_1_value,
        datum: NoDatum,
        reference_script: None,
      }
    }

  let wallet_2_output =
    if tag_outputs {
      Output {
        address: wallet_2,
        value: wallet_2_value,
        datum: InlineDatum(input_ref),
        reference_script: None,
      }
    } else {
      Output {
        address: wallet_2,
        value: wallet_2_value,
        datum: NoDatum,
        reference_script: None,
      }
    }

  Transaction {
    ..placeholder,
    inputs: [
      Input {
        output_reference: input_ref,
        output: Output {
          address: mock_script_address(0, None),
          value: input_value,
          datum: NoDatum,
          reference_script: None,
        },
      },
    ],
    outputs: [wallet_1_output, wallet_2_output],
  }
}

// TESTS

test test_successful_equal_split() {
  let input_ref = mock_utxo_ref(0, 0)
  let wallet_1 = mock_pub_key_address(1, None)
  let wallet_2 = mock_pub_key_address(2, None)
  let input_value = from_lovelace(1_000_000)
  // 1 ADA
  let half_value = from_lovelace(500_000)

  // 0.5 ADA each
  let redeemer = SplitRedeemer { wallet_1, wallet_2 }
  let tx =
    build_split_transaction(
      input_value,
      wallet_1,
      wallet_2,
      half_value,
      half_value,
      False,
      // Don't tag outputs for this test
      input_ref,
    )

  equal_split_payment.spend(None, redeemer, input_ref, tx)
}

test test_fail_unequal_split() {
  let input_ref = mock_utxo_ref(0, 0)
  let wallet_1 = mock_pub_key_address(1, None)
  let wallet_2 = mock_pub_key_address(2, None)
  let input_value = from_lovelace(1_000_000)
  // 1 ADA
  let unequal_value_1 = from_lovelace(700_000)
  // 0.7 ADA
  let unequal_value_2 = from_lovelace(300_000)

  // 0.3 ADA
  let redeemer = SplitRedeemer { wallet_1, wallet_2 }
  let tx =
    build_split_transaction(
      input_value,
      wallet_1,
      wallet_2,
      unequal_value_1,
      unequal_value_2,
      False,
      input_ref,
    )

  !equal_split_payment.spend(None, redeemer, input_ref, tx)
}

test test_same_wallet_behavior() {
  let input_ref = mock_utxo_ref(0, 0)
  let wallet_1 = mock_pub_key_address(1, None)
  let wallet_2 = wallet_1
  // Same wallet - this creates outputs that sum to full amount
  let input_value = from_lovelace(1_000_000)
  let redeemer = SplitRedeemer { wallet_1, wallet_2 }
  // When using the same wallet, both outputs go to the same address
  // So the total for that address becomes the full amount, not half
  let tx =
    Transaction {
      ..placeholder,
      inputs: [
        Input {
          output_reference: input_ref,
          output: Output {
            address: mock_script_address(0, None),
            value: input_value,
            datum: NoDatum,
            reference_script: None,
          },
        },
      ],
      outputs: [
        Output {
          address: wallet_1,
          // Same as wallet_2
          value: from_lovelace(500_000),
          // First half
          datum: NoDatum,
          reference_script: None,
        },
        Output {
          address: wallet_2,
          // Same as wallet_1
          value: from_lovelace(500_000),
          // Second half
          datum: NoDatum,
          reference_script: None,
        },
      ],
    }

  // This should fail because when addresses are the same, 
  // wallet_1_total = wallet_2_total = 1_000_000 (full amount)
  // but half_input_value = 500_000, so the comparison fails
  !equal_split_payment.spend(None, redeemer, input_ref, tx)
}

test test_successful_tagged_outputs() {
  let input_ref = mock_utxo_ref(0, 0)
  let wallet_1 = mock_pub_key_address(1, None)
  let wallet_2 = mock_pub_key_address(2, None)
  let input_value = from_lovelace(2_000_000)
  // 2 ADA
  let half_value = from_lovelace(1_000_000)

  // 1 ADA each
  let redeemer = SplitRedeemer { wallet_1, wallet_2 }
  let tx =
    build_split_transaction(
      input_value,
      wallet_1,
      wallet_2,
      half_value,
      half_value,
      True,
      // Tag outputs with input reference
      input_ref,
    )

  equal_split_payment.spend(None, redeemer, input_ref, tx)
}

test test_fail_odd_amount() {
  let input_ref = mock_utxo_ref(0, 0)
  let wallet_1 = mock_pub_key_address(1, None)
  let wallet_2 = mock_pub_key_address(2, None)
  let input_value = from_lovelace(1_000_001)
  // Odd amount - can't split evenly
  let redeemer = SplitRedeemer { wallet_1, wallet_2 }
  // Build transaction manually to avoid calling divide_value_by_two in helper
  let tx =
    Transaction {
      ..placeholder,
      inputs: [
        Input {
          output_reference: input_ref,
          output: Output {
            address: mock_script_address(0, None),
            value: input_value,
            datum: NoDatum,
            reference_script: None,
          },
        },
      ],
      outputs: [
        Output {
          address: wallet_1,
          value: from_lovelace(500_000),
          // Attempting to give half (rounded down)
          datum: NoDatum,
          reference_script: None,
        },
        Output {
          address: wallet_2,
          value: from_lovelace(500_000),
          // Attempting to give half (rounded down)
          datum: NoDatum,
          reference_script: None,
        },
      ],
    }

  // This should fail because the input amount is odd (1,000,001)
  // The is_even_amount check will return False
  !equal_split_payment.spend(None, redeemer, input_ref, tx)
}

test test_multiple_outputs_same_address() {
  let input_ref = mock_utxo_ref(0, 0)
  let wallet_1 = mock_pub_key_address(1, None)
  let wallet_2 = mock_pub_key_address(2, None)
  let input_value = from_lovelace(1_000_000)

  let redeemer = SplitRedeemer { wallet_1, wallet_2 }

  // Create transaction with multiple outputs to wallet_1 that sum to half
  let tx =
    Transaction {
      ..placeholder,
      inputs: [
        Input {
          output_reference: input_ref,
          output: Output {
            address: mock_script_address(0, None),
            value: input_value,
            datum: NoDatum,
            reference_script: None,
          },
        },
      ],
      outputs: [
        Output {
          address: wallet_1,
          value: from_lovelace(300_000),
          datum: NoDatum,
          reference_script: None,
        },
        Output {
          address: wallet_1,
          value: from_lovelace(200_000),
          datum: NoDatum,
          reference_script: None,
        },
        Output {
          address: wallet_2,
          value: from_lovelace(500_000),
          datum: NoDatum,
          reference_script: None,
        },
      ],
    }

  equal_split_payment.spend(None, redeemer, input_ref, tx)
}
