use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Address, VerificationKey}
use cardano/assets.{from_lovelace}
use cardano/transaction.{Input, NoDatum, Output, OutputReference, Transaction}
use mocktail.{
  complete, mock_pub_key_address, mock_pub_key_hash, mock_pub_key_output,
  mock_utxo_ref, mocktail_tx,
}

// Secure datum that stores the authorized signer (set when funds are locked)
pub type SecureDatum {
  authorized_signer: VerificationKeyHash,
}

// Could add more fields like amount limits, expiration, etc.

// Simple redeemer - no sensitive authorization data here
pub type SecureRedeemer {
  // Could be used for different actions, metadata, etc.
  action: Int,
}

validator secure_signature_validator {
  spend(
    datum_opt: Option<SecureDatum>,
    redeemer: SecureRedeemer,
    _input: OutputReference,
    tx: Transaction,
  ) {
    expect Some(datum) = datum_opt
    // Only the authorized signer (from datum) can unlock funds
    let is_authorized = list.has(tx.extra_signatories, datum.authorized_signer)
    // Could add different logic based on redeemer action
    let valid_action = redeemer.action >= 0
    trace @"Authorized signer": datum.authorized_signer
    trace @"Transaction signatories": tx.extra_signatories
    trace @"Is authorized": is_authorized
    trace @"Valid action": valid_action
    is_authorized? && valid_action?
  }

  else(_) {
    fail
  }
}

// Helper function to create a test input
fn create_secure_test_input() -> Input {
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

// Test: Success case - authorized signer unlocks funds
test test_secure_success_authorized_signer() {
  let alice_key = mock_pub_key_hash(1)
  let datum = Some(SecureDatum { authorized_signer: alice_key })
  let redeemer = SecureRedeemer { action: 0 }
  let base_tx = mocktail_tx() |> complete()
  // Alice (the authorized signer) signs the transaction
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_secure_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(2, None),
          from_lovelace(9_000_000),
        ),
      ],
      extra_signatories: [alice_key],
    }
  // Alice signs
  secure_signature_validator.spend(
    datum,
    redeemer,
    mock_utxo_ref(0, 0),
    tx_final,
  )
}

// Test: Failure case - unauthorized person tries to spend
test test_secure_failure_unauthorized_signer() {
  let alice_key = mock_pub_key_hash(1)
  let bob_key = mock_pub_key_hash(2)
  let datum = Some(SecureDatum { authorized_signer: alice_key })
  // Alice is authorized
  let redeemer = SecureRedeemer { action: 0 }
  let base_tx = mocktail_tx() |> complete()
  // Bob tries to spend but he's not authorized
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_secure_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(3, None),
          from_lovelace(9_000_000),
        ),
      ],
      extra_signatories: [bob_key],
    }
  // Bob signs, but Alice is required
  !secure_signature_validator.spend(
    datum,
    redeemer,
    mock_utxo_ref(0, 0),
    tx_final,
  )
}

// Test: Failure case - no signature provided
test test_secure_failure_no_signature() {
  let alice_key = mock_pub_key_hash(1)
  let datum = Some(SecureDatum { authorized_signer: alice_key })
  let redeemer = SecureRedeemer { action: 0 }
  let base_tx = mocktail_tx() |> complete()
  // Transaction with no signatures
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_secure_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(2, None),
          from_lovelace(9_000_000),
        ),
      ],
      extra_signatories: [],
    }
  // No signatures
  !secure_signature_validator.spend(
    datum,
    redeemer,
    mock_utxo_ref(0, 0),
    tx_final,
  )
}

// Test: Success case - authorized signer with multiple signatures
test test_secure_success_multiple_signatures() {
  let alice_key = mock_pub_key_hash(1)
  let bob_key = mock_pub_key_hash(2)
  let charlie_key = mock_pub_key_hash(3)
  let datum = Some(SecureDatum { authorized_signer: alice_key })
  let redeemer = SecureRedeemer { action: 0 }
  let base_tx = mocktail_tx() |> complete()
  // Transaction signed by multiple people, including Alice (the authorized one)
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_secure_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(4, None),
          from_lovelace(9_000_000),
        ),
      ],
      extra_signatories: [bob_key, alice_key, charlie_key],
    }
  // Alice is in the list
  secure_signature_validator.spend(
    datum,
    redeemer,
    mock_utxo_ref(0, 0),
    tx_final,
  )
}

// Test: Failure case - invalid action
test test_secure_failure_invalid_action() {
  let alice_key = mock_pub_key_hash(1)
  let datum = Some(SecureDatum { authorized_signer: alice_key })
  let redeemer = SecureRedeemer { action: -1 }
  // Invalid negative action
  let base_tx = mocktail_tx() |> complete()
  // Alice signs (authorized) but uses invalid action
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_secure_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(2, None),
          from_lovelace(9_000_000),
        ),
      ],
      extra_signatories: [alice_key],
    }
  !secure_signature_validator.spend(
    datum,
    redeemer,
    mock_utxo_ref(0, 0),
    tx_final,
  )
}

// Test: Failure case - no datum provided
test test_secure_failure_no_datum() {
  let redeemer = SecureRedeemer { action: 0 }
  let base_tx = mocktail_tx() |> complete()
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_secure_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(2, None),
          from_lovelace(9_000_000),
        ),
      ],
      extra_signatories: [mock_pub_key_hash(1)],
    }
  !secure_signature_validator.spend(
    None,
    redeemer,
    mock_utxo_ref(0, 0),
    tx_final,
  )
}

// Test: Edge case - empty authorized signer in datum
test test_secure_failure_empty_authorized_signer() {
  let empty_key = #""
  let datum = Some(SecureDatum { authorized_signer: empty_key })
  let redeemer = SecureRedeemer { action: 0 }
  let base_tx = mocktail_tx() |> complete()
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_secure_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(2, None),
          from_lovelace(9_000_000),
        ),
      ],
      extra_signatories: [mock_pub_key_hash(1)],
    }
  // Valid signature, but doesn't match empty key
  !secure_signature_validator.spend(
    datum,
    redeemer,
    mock_utxo_ref(0, 0),
    tx_final,
  )
}
