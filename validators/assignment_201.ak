use aiken/collection/list
use aiken/interval.{Finite, NegativeInfinity, PositiveInfinity}
use cardano/address.{Address, VerificationKey}
use cardano/assets.{from_lovelace}
use cardano/transaction.{
  Input, NoDatum, Output, OutputReference, Transaction, ValidityRange,
}
use mocktail.{
  complete, invalid_before, invalid_hereafter, mock_pub_key_address,
  mock_pub_key_hash, mock_pub_key_output, mock_utxo_ref, mocktail_tx,
}

// Datum to store the deadline
pub type DeadlineDatum {
  deadline: Int,
}

// POSIX time in milliseconds

// Helper function to check if we're before the deadline
fn is_before_deadline(validity_range: ValidityRange, deadline: Int) -> Bool {
  when validity_range.lower_bound.bound_type is {
    Finite(n) -> n < deadline
    // Transaction valid from time 'n', must be before deadline
    NegativeInfinity -> True
    // No lower bound, so always valid (including before deadline)
    PositiveInfinity -> False
  }
  // Invalid case
}

validator simple_deadline {
  spend(
    datum_opt: Option<DeadlineDatum>,
    _redeemer: Data,
    _input: OutputReference,
    tx: Transaction,
  ) {
    expect Some(datum) = datum_opt
    // Check exactly one input and one output
    let has_one_input = list.length(tx.inputs) == 1
    let has_one_output = list.length(tx.outputs) == 1
    // Check if we're before the deadline
    let before_deadline = is_before_deadline(tx.validity_range, datum.deadline)
    // All conditions must be true (with traces for debugging)
    has_one_input? && has_one_output? && before_deadline?
  }

  else(_) {
    fail
  }
}

// Helper function to create a simple input
fn create_test_input() -> Input {
  Input {
    output_reference: mock_utxo_ref(0, 0),
    output: Output {
      address: Address {
        payment_credential: VerificationKey(mock_pub_key_hash(0)),
        stake_credential: None,
      },
      value: from_lovelace(10_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

// Test: Success case - transaction valid before deadline
test test_success_before_deadline() {
  let datum = Some(DeadlineDatum { deadline: 1767225600000 })
  // Jan 1, 2026
  // Create base transaction with time constraints
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1735689600000)
      // Valid from Jan 1, 2025
      |> invalid_hereafter(True, 1767139200000)
      // Valid until Dec 31, 2025
      |> complete()
  // Create transaction with exactly 1 input and 1 output using mocktail helpers
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          from_lovelace(9_000_000),
        ),
      ],
    }
  simple_deadline.spend(datum, Void, mock_utxo_ref(0, 0), tx_final)
}

// Test: Failure case - transaction valid after deadline
test test_failure_after_deadline() {
  let datum = Some(DeadlineDatum { deadline: 1767225600000 })
  // Jan 1, 2026
  // Create base transaction valid after deadline
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1767312000000)
      // Valid from Jan 2, 2026 (after deadline)
      |> complete()
  // Create transaction with exactly 1 input and 1 output using mocktail helpers
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          from_lovelace(9_000_000),
        ),
      ],
    }
  // This should fail because the earliest this can be submitted is after deadline
  !simple_deadline.spend(datum, Void, mock_utxo_ref(0, 0), tx_final)
}

// Test: Edge case - transaction at exact deadline should fail
test test_failure_at_deadline() {
  let datum = Some(DeadlineDatum { deadline: 1767225600000 })
  // Jan 1, 2026
  // Create base transaction valid exactly at deadline
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1767225600000)
      // Valid from exactly Jan 1, 2026
      |> complete()
  // Create transaction with exactly 1 input and 1 output using mocktail helpers
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          from_lovelace(9_000_000),
        ),
      ],
    }
  // This should fail because we want BEFORE deadline, not AT deadline
  !simple_deadline.spend(datum, Void, mock_utxo_ref(0, 0), tx_final)
}

// Test: Failure case - no inputs
test test_failure_no_inputs() {
  let datum = Some(DeadlineDatum { deadline: 1767225600000 })
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1735689600000)
      // Valid from Jan 1, 2025
      |> invalid_hereafter(True, 1767139200000)
      // Valid until Dec 31, 2025
      |> complete()
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [],
      outputs: // No inputs - should fail
      [
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          from_lovelace(9_000_000),
        ),
      ],
    }
  !simple_deadline.spend(datum, Void, mock_utxo_ref(0, 0), tx_final)
}

// Test: Failure case - multiple inputs
test test_failure_multiple_inputs() {
  let datum = Some(DeadlineDatum { deadline: 1767225600000 })
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1735689600000)
      // Valid from Jan 1, 2025
      |> invalid_hereafter(True, 1767139200000)
      // Valid until Dec 31, 2025
      |> complete()
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_test_input(), create_test_input()],
      outputs: // Two inputs - should fail
      [
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          from_lovelace(9_000_000),
        ),
      ],
    }
  !simple_deadline.spend(datum, Void, mock_utxo_ref(0, 0), tx_final)
}

// Test: Failure case - no outputs
test test_failure_no_outputs() {
  let datum = Some(DeadlineDatum { deadline: 1767225600000 })
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1735689600000)
      // Valid from Jan 1, 2025
      |> invalid_hereafter(True, 1767139200000)
      // Valid until Dec 31, 2025
      |> complete()
  let tx_final =
    Transaction { ..base_tx, inputs: [create_test_input()], outputs: [] }
  // No outputs - should fail
  !simple_deadline.spend(datum, Void, mock_utxo_ref(0, 0), tx_final)
}

// Test: Failure case - multiple outputs
test test_failure_multiple_outputs() {
  let datum = Some(DeadlineDatum { deadline: 1767225600000 })
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1735689600000)
      // Valid from Jan 1, 2025
      |> invalid_hereafter(True, 1767139200000)
      // Valid until Dec 31, 2025
      |> complete()
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          from_lovelace(5_000_000),
        ),
        mock_pub_key_output(
          mock_pub_key_address(2, None),
          from_lovelace(4_000_000),
        ),
      ],
    }
  // Two outputs - should fail
  !simple_deadline.spend(datum, Void, mock_utxo_ref(0, 0), tx_final)
}

// Test: Failure case - multiple inputs AND multiple outputs (double failure)
test test_failure_multiple_inputs_and_outputs() {
  let datum = Some(DeadlineDatum { deadline: 1767225600000 })
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1735689600000)
      // Valid from Jan 1, 2025
      |> invalid_hereafter(True, 1767139200000)
      // Valid until Dec 31, 2025
      |> complete()
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_test_input(), create_test_input()],
      outputs: // Two inputs
      [
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          from_lovelace(5_000_000),
        ),
        mock_pub_key_output(
          mock_pub_key_address(2, None),
          from_lovelace(4_000_000),
        ),
      ],
    }
  // Two outputs - both conditions fail
  !simple_deadline.spend(datum, Void, mock_utxo_ref(0, 0), tx_final)
}

// Test: Edge case - valid time but wrong input/output count
test test_failure_valid_time_wrong_counts() {
  let datum = Some(DeadlineDatum { deadline: 1767225600000 })
  // Jan 1, 2026
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1735689600000)
      // Valid from Jan 1, 2025 (before deadline)
      |> invalid_hereafter(True, 1767139200000)
      // Valid until Dec 31, 2025
      |> complete()
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_test_input(), create_test_input()],
      outputs: // Wrong: 2 inputs
      [
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          from_lovelace(9_000_000),
        ),
      ],
    }
  // Correct: 1 output
  // Should fail even though time is valid because input count is wrong
  !simple_deadline.spend(datum, Void, mock_utxo_ref(0, 0), tx_final)
}

// Test: Boundary case - exactly at limits but wrong timing
test test_failure_correct_counts_wrong_time() {
  let datum = Some(DeadlineDatum { deadline: 1767225600000 })
  // Jan 1, 2026
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1767312000000)
      // Valid from Jan 2, 2026 (after deadline)
      |> complete()
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_test_input()],
      outputs: // Correct: 1 input
      [
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          from_lovelace(9_000_000),
        ),
      ],
    }
  // Correct: 1 output
  // Should fail because timing is wrong even though counts are correct
  !simple_deadline.spend(datum, Void, mock_utxo_ref(0, 0), tx_final)
}
