use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Address, VerificationKey}
use cardano/assets.{from_lovelace}
use cardano/transaction.{Input, NoDatum, Output, OutputReference, Transaction}
use mocktail.{
  complete, mock_pub_key_address, mock_pub_key_hash, mock_pub_key_output,
  mock_utxo_ref, mocktail_tx,
}

// Redeemer that specifies which public key hash must have signed the transaction
pub type SignatureRedeemer {
  required_signer: VerificationKeyHash,
}

validator signature_validator {
  spend(
    _datum_opt: Option<Data>,
    redeemer: SignatureRedeemer,
    _input: OutputReference,
    tx: Transaction,
  ) {
    // Check if the required signer's key hash is in the transaction's extra signatories
    let is_signed_by_required_key =
      list.has(tx.extra_signatories, redeemer.required_signer)
    // Add traces for debugging
    trace @"Required signer": redeemer.required_signer
    trace @"Transaction signatories": tx.extra_signatories
    trace @"Is signed by required key": is_signed_by_required_key
    // Validator succeeds if the transaction is signed by the required key
    is_signed_by_required_key?
  }

  else(_) {
    fail
  }
}

// Helper function to create a test input
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

// Test: Success case - transaction signed by the required key
test test_signature_success() {
  let alice_key = mock_pub_key_hash(1)
  let redeemer = SignatureRedeemer { required_signer: alice_key }
  let base_tx = mocktail_tx() |> complete()
  // Create transaction signed by Alice (the required signer)
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(2, None),
          from_lovelace(9_000_000),
        ),
      ],
      extra_signatories: [alice_key],
    }
  // Alice signs the transaction
  signature_validator.spend(None, redeemer, mock_utxo_ref(0, 0), tx_final)
}

// Test: Failure case - transaction signed by wrong key
test test_signature_failure_wrong_signer() {
  let alice_key = mock_pub_key_hash(1)
  let bob_key = mock_pub_key_hash(2)
  let redeemer = SignatureRedeemer { required_signer: alice_key }
  // Requires Alice
  let base_tx = mocktail_tx() |> complete()
  // Create transaction signed by Bob (not the required signer)
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(3, None),
          from_lovelace(9_000_000),
        ),
      ],
      extra_signatories: [bob_key],
    }
  // Bob signs, but Alice is required
  !signature_validator.spend(None, redeemer, mock_utxo_ref(0, 0), tx_final)
}

// Test: Failure case - transaction has no signatures
test test_signature_failure_no_signatures() {
  let alice_key = mock_pub_key_hash(1)
  let redeemer = SignatureRedeemer { required_signer: alice_key }
  let base_tx = mocktail_tx() |> complete()
  // Create transaction with no extra signatories
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(2, None),
          from_lovelace(9_000_000),
        ),
      ],
      extra_signatories: [],
    }
  // No signatures at all
  !signature_validator.spend(None, redeemer, mock_utxo_ref(0, 0), tx_final)
}

// Test: Success case - transaction has multiple signatures including the required one
test test_signature_success_multiple_signers() {
  let alice_key = mock_pub_key_hash(1)
  let bob_key = mock_pub_key_hash(2)
  let charlie_key = mock_pub_key_hash(3)
  let redeemer = SignatureRedeemer { required_signer: alice_key }
  let base_tx = mocktail_tx() |> complete()
  // Create transaction with multiple signatories, including Alice
  let tx_final =
    Transaction {
      ..base_tx,
      inputs: [create_test_input()],
      outputs: [
        mock_pub_key_output(
          mock_pub_key_address(4, None),
          from_lovelace(9_000_000),
        ),
      ],
      extra_signatories: [bob_key, alice_key, charlie_key],
    }
  // Alice is in the list
  signature_validator.spend(None, redeemer, mock_utxo_ref(0, 0), tx_final)
}

// Test: Edge case - empty key hash should fail
test test_signature_failure_empty_key() {
  let empty_key = #""
  // Empty verification key hash
  let redeemer = SignatureRedeemer { required_signer: empty_key }
  let base_tx = mocktail_tx() |> complete()
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
      extra_signatories: [mock_pub_key_hash(1)],
    }
  // Valid signature, but not matching empty key
  !signature_validator.spend(None, redeemer, mock_utxo_ref(0, 0), tx_final)
}
