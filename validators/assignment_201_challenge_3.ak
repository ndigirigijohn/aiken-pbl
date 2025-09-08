use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
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

// Datum stores the deadline and administrator info
pub type ComplexDeadlineDatum {
  deadline: Int,
  // POSIX time in milliseconds
  administrator: VerificationKeyHash,
}

// Admin who can spend after deadline

// Simple redeemer - could be extended for different actions
pub type ComplexRedeemer {
  action: Int,
}

// Helper function to check if current time is before deadline
fn is_before_deadline(validity_range: ValidityRange, deadline: Int) -> Bool {
  when validity_range.lower_bound.bound_type is {
    Finite(n) -> n < deadline
    // Transaction valid from time 'n', must be before deadline
    NegativeInfinity -> True
    // No lower bound, always valid (including before deadline)
    PositiveInfinity -> False
  }
  // Invalid case
}

// Helper function to check if current time is after deadline
fn is_after_deadline(validity_range: ValidityRange, deadline: Int) -> Bool {
  when validity_range.lower_bound.bound_type is {
    Finite(n) -> n >= deadline
    // Transaction valid from time 'n', must be at or after deadline
    NegativeInfinity -> False
    // No lower bound, could be before deadline
    PositiveInfinity -> True
  }
  // Always after any deadline
}

// Helper function to count unique output addresses
fn count_unique_addresses(outputs: List<Output>) -> Int {
  let unique_addresses =
    list.foldr(
      outputs,
      [],
      fn(output, acc) {
        if list.has(acc, output.address) {
          acc
        } else {
          [output.address, ..acc]
        }
      },
    )
  list.length(unique_addresses)
}

// Helper function to check if transaction has outputs to at least N different addresses
fn has_outputs_to_multiple_addresses(
  outputs: List<Output>,
  min_addresses: Int,
) -> Bool {
  count_unique_addresses(outputs) >= min_addresses
}

validator complex_deadline_validator {
  spend(
    datum_opt: Option<ComplexDeadlineDatum>,
    _redeemer: ComplexRedeemer,
    _input: OutputReference,
    tx: Transaction,
  ) {
    expect Some(datum) = datum_opt
    let before_deadline = is_before_deadline(tx.validity_range, datum.deadline)
    let after_deadline = is_after_deadline(tx.validity_range, datum.deadline)
    let has_multiple_outputs = has_outputs_to_multiple_addresses(tx.outputs, 2)
    let admin_signed = list.has(tx.extra_signatories, datum.administrator)
    // Add traces for debugging
    trace @"Deadline (POSIX ms)": datum.deadline
    trace @"Before deadline": before_deadline
    trace @"After deadline": after_deadline
    trace @"Unique address count": count_unique_addresses(tx.outputs)
    trace @"Has multiple outputs": has_multiple_outputs
    trace @"Admin signed": admin_signed
    trace @"Administrator": datum.administrator
    // Complex conditional logic:
    // BEFORE deadline: Must send to at least 2 different addresses
    // AFTER deadline: Must be signed by administrator
    or {
      and {
        before_deadline?,
        has_multiple_outputs?,
      },
      and {
        after_deadline?,
        admin_signed?,
      },
    }
  }

  else(_) {
    fail
  }
}

// Helper function to create a test input
fn create_complex_test_input() -> Input {
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

// ===== TESTS FOR "BEFORE DEADLINE" CONDITIONS =====

// Test: Success case - before deadline with outputs to 2 different addresses
test test_before_deadline_success_two_addresses() {
  let admin_key = mock_pub_key_hash(99)
  let datum =
    Some(
      ComplexDeadlineDatum {
        deadline: 1767225600000,
        // Jan 1, 2026
        administrator: admin_key,
      },
    )
  let redeemer = ComplexRedeemer { action: 0 }
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1735689600000)
      // Valid from Jan 1, 2025
      |> invalid_hereafter(True, 1767139200000)
      // Valid until Dec 31, 2025 (before deadline)
      |> complete()
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_complex_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          // Address 1
          from_lovelace(4_000_000),
        ),
        mock_pub_key_output(
          mock_pub_key_address(2, None),
          // Address 2 (different)
          from_lovelace(5_000_000),
        ),
      ],
      extra_signatories: [],
    }
  // No admin signature needed before deadline
  complex_deadline_validator.spend(
    datum,
    redeemer,
    mock_utxo_ref(0, 0),
    tx_final,
  )
}

// Test: Success case - before deadline with outputs to 3 different addresses
test test_before_deadline_success_three_addresses() {
  let admin_key = mock_pub_key_hash(99)
  let datum =
    Some(
      ComplexDeadlineDatum { deadline: 1767225600000, administrator: admin_key },
    )
  let redeemer = ComplexRedeemer { action: 0 }
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1735689600000)
      |> invalid_hereafter(True, 1767139200000)
      |> complete()
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_complex_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          // Address 1
          from_lovelace(3_000_000),
        ),
        mock_pub_key_output(
          mock_pub_key_address(2, None),
          // Address 2
          from_lovelace(3_000_000),
        ),
        mock_pub_key_output(
          mock_pub_key_address(3, None),
          // Address 3
          from_lovelace(3_000_000),
        ),
      ],
      extra_signatories: [],
    }
  complex_deadline_validator.spend(
    datum,
    redeemer,
    mock_utxo_ref(0, 0),
    tx_final,
  )
}

// Test: Failure case - before deadline but only 1 address
test test_before_deadline_failure_one_address() {
  let admin_key = mock_pub_key_hash(99)
  let datum =
    Some(
      ComplexDeadlineDatum { deadline: 1767225600000, administrator: admin_key },
    )
  let redeemer = ComplexRedeemer { action: 0 }
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1735689600000)
      |> invalid_hereafter(True, 1767139200000)
      |> complete()
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_complex_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          // Only 1 address
          from_lovelace(9_000_000),
        ),
      ],
      extra_signatories: [],
    }
  !complex_deadline_validator.spend(
    datum,
    redeemer,
    mock_utxo_ref(0, 0),
    tx_final,
  )
}

// Test: Failure case - before deadline, same address twice (counts as 1)
test test_before_deadline_failure_same_address_twice() {
  let admin_key = mock_pub_key_hash(99)
  let datum =
    Some(
      ComplexDeadlineDatum { deadline: 1767225600000, administrator: admin_key },
    )
  let redeemer = ComplexRedeemer { action: 0 }
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1735689600000)
      |> invalid_hereafter(True, 1767139200000)
      |> complete()
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_complex_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          // Address 1
          from_lovelace(4_000_000),
        ),
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          // Same address again
          from_lovelace(5_000_000),
        ),
      ],
      extra_signatories: [],
    }
  !complex_deadline_validator.spend(
    datum,
    redeemer,
    mock_utxo_ref(0, 0),
    tx_final,
  )
}

// ===== TESTS FOR "AFTER DEADLINE" CONDITIONS =====

// Test: Success case - after deadline with admin signature
test test_after_deadline_success_admin_signed() {
  let admin_key = mock_pub_key_hash(99)
  let datum =
    Some(
      ComplexDeadlineDatum {
        deadline: 1767225600000,
        // Jan 1, 2026
        administrator: admin_key,
      },
    )
  let redeemer = ComplexRedeemer { action: 0 }
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1767312000000)
      // Valid from Jan 2, 2026 (after deadline)
      |> complete()
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_complex_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          // Can send to just 1 address after deadline
          from_lovelace(9_000_000),
        ),
      ],
      extra_signatories: [admin_key],
    }
  // Admin signature required
  complex_deadline_validator.spend(
    datum,
    redeemer,
    mock_utxo_ref(0, 0),
    tx_final,
  )
}

// Test: Failure case - after deadline but no admin signature
test test_after_deadline_failure_no_admin_signature() {
  let admin_key = mock_pub_key_hash(99)
  let datum =
    Some(
      ComplexDeadlineDatum { deadline: 1767225600000, administrator: admin_key },
    )
  let redeemer = ComplexRedeemer { action: 0 }
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1767312000000)
      // After deadline
      |> complete()
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_complex_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          from_lovelace(9_000_000),
        ),
      ],
      extra_signatories: [],
    }
  // No admin signature
  !complex_deadline_validator.spend(
    datum,
    redeemer,
    mock_utxo_ref(0, 0),
    tx_final,
  )
}

// Test: Failure case - after deadline, wrong person signs
test test_after_deadline_failure_wrong_signer() {
  let admin_key = mock_pub_key_hash(99)
  let wrong_key = mock_pub_key_hash(88)
  let datum =
    Some(
      ComplexDeadlineDatum { deadline: 1767225600000, administrator: admin_key },
    )
  let redeemer = ComplexRedeemer { action: 0 }
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1767312000000)
      |> complete()
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_complex_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          from_lovelace(9_000_000),
        ),
      ],
      extra_signatories: [wrong_key],
    }
  // Wrong person signs
  !complex_deadline_validator.spend(
    datum,
    redeemer,
    mock_utxo_ref(0, 0),
    tx_final,
  )
}

// ===== EDGE CASE TESTS =====

// Test: Edge case - exactly at deadline should follow "after" rules
test test_exactly_at_deadline_requires_admin() {
  let admin_key = mock_pub_key_hash(99)
  let datum =
    Some(
      ComplexDeadlineDatum { deadline: 1767225600000, administrator: admin_key },
    )
  let redeemer = ComplexRedeemer { action: 0 }
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1767225600000)
      // Exactly at deadline
      |> complete()
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_complex_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          from_lovelace(4_000_000),
        ),
        mock_pub_key_output(
          mock_pub_key_address(2, None),
          from_lovelace(5_000_000),
        ),
      ],
      extra_signatories: [admin_key],
    }
  // Must have admin signature at deadline
  complex_deadline_validator.spend(
    datum,
    redeemer,
    mock_utxo_ref(0, 0),
    tx_final,
  )
}

// Test: Success case - after deadline with multiple addresses AND admin signature
test test_after_deadline_success_multiple_addresses_with_admin() {
  let admin_key = mock_pub_key_hash(99)
  let datum =
    Some(
      ComplexDeadlineDatum { deadline: 1767225600000, administrator: admin_key },
    )
  let redeemer = ComplexRedeemer { action: 0 }
  let base_tx =
    mocktail_tx()
      |> invalid_before(True, 1767312000000)
      |> complete()
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_complex_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(1, None),
          from_lovelace(4_000_000),
        ),
        mock_pub_key_output(
          mock_pub_key_address(2, None),
          from_lovelace(5_000_000),
        ),
      ],
      extra_signatories: [admin_key],
    }
  // Admin signature is sufficient after deadline
  complex_deadline_validator.spend(
    datum,
    redeemer,
    mock_utxo_ref(0, 0),
    tx_final,
  )
}
