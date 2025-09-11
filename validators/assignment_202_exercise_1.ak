use aiken/collection/dict
use aiken/collection/list
use aiken/option
use cardano/address.{Address, VerificationKey}
use cardano/assets.{
  AssetName, PolicyId, from_asset, from_lovelace, merge, tokens,
}
use cardano/transaction.{NoDatum, Output, Transaction, placeholder}
use mocktail.{mock_pub_key_address, mock_pub_key_hash}

pub type MintRedeemer {
  recipient_address: Address,
  asset_name: AssetName,
  total_amount: Int,
}

validator equal_share_mint {
  mint(redeemer: MintRedeemer, policy_id: PolicyId, tx: Transaction) {
    let MintRedeemer { recipient_address, asset_name, total_amount } = redeemer
    let Transaction { outputs, extra_signatories, mint, .. } = tx

    // Total amount must be even for equal splitting
    let is_even_amount = total_amount % 2 == 0
    let half_amount = total_amount / 2

    // Verify exactly the requested amount is being minted
    let mint_pairs = mint |> tokens(policy_id) |> dict.to_pairs()
    let is_correct_mint =
      when mint_pairs is {
        [] -> total_amount == 0
        // Zero minting case
        [Pair(minted_asset_name, minted_amount)] ->
          minted_asset_name == asset_name && minted_amount == total_amount
        _ -> False
      }

    // Multiple tokens being minted (not allowed)
    // Find outputs going to each address
    let signer_outputs = get_outputs_by_signer(outputs, extra_signatories)
    let recipient_outputs = get_outputs_by_address(outputs, recipient_address)

    // Calculate token amounts sent to each party
    let signer_token_amount =
      calculate_token_amount(signer_outputs, policy_id, asset_name)
    let recipient_token_amount =
      calculate_token_amount(recipient_outputs, policy_id, asset_name)

    // Verify equal distribution
    let is_equal_distribution =
      signer_token_amount == half_amount && recipient_token_amount == half_amount

    // Verify transaction is signed
    let is_signed = !list.is_empty(extra_signatories)

    and {
      is_even_amount?,
      is_correct_mint?,
      is_equal_distribution?,
      is_signed?,
    }
  }

  else(_) {
    fail
  }
}

fn get_outputs_by_signer(
  outputs: List<Output>,
  signers: List<ByteArray>,
) -> List<Output> {
  list.filter(
    outputs,
    fn(output) {
      when output.address.payment_credential is {
        VerificationKey(vh) -> list.has(signers, vh)
        _ -> False
      }
    },
  )
}

fn get_outputs_by_address(
  outputs: List<Output>,
  target_address: Address,
) -> List<Output> {
  list.filter(outputs, fn(output) { output.address == target_address })
}

fn calculate_token_amount(
  outputs: List<Output>,
  policy_id: PolicyId,
  asset_name: AssetName,
) -> Int {
  list.foldl(
    outputs,
    0,
    fn(output, acc) {
      let token_amount =
        output.value
          |> tokens(policy_id)
          |> dict.get(asset_name)
          |> option.or_else(0)
      acc + token_amount
    },
  )
}

// Helper function to build transaction with mint and outputs
fn build_test_transaction(
  signer_hash: ByteArray,
  recipient_address: Address,
  signer_value: assets.Value,
  recipient_value: assets.Value,
  mint_value: assets.Value,
  include_signer: Bool,
) -> Transaction {
  let signer_outputs =
    if include_signer {
      [
        Output {
          address: mock_pub_key_address(1, None),
          value: signer_value,
          datum: NoDatum,
          reference_script: None,
        },
      ]
    } else {
      []
    }

  let recipient_output =
    Output {
      address: recipient_address,
      value: recipient_value,
      datum: NoDatum,
      reference_script: None,
    }

  let final_outputs = list.concat(signer_outputs, [recipient_output])

  let extra_signatories =
    if include_signer {
      [signer_hash]
    } else {
      []
    }

  Transaction {
    ..placeholder,
    outputs: final_outputs,
    extra_signatories: extra_signatories,
    mint: mint_value,
  }
}

test test_successful_equal_mint() {
  let policy_id = #"abcd1234"
  let asset_name = "MYTOKEN"
  let total_amount = 100
  let signer_hash = mock_pub_key_hash(1)
  let recipient_address = mock_pub_key_address(2, None)

  let redeemer = MintRedeemer { recipient_address, asset_name, total_amount }

  let mint_value = from_asset(policy_id, asset_name, total_amount)
  let signer_value =
    merge(from_lovelace(2_000_000), from_asset(policy_id, asset_name, 50))
  let recipient_value =
    merge(from_lovelace(2_000_000), from_asset(policy_id, asset_name, 50))

  let tx =
    build_test_transaction(
      signer_hash,
      recipient_address,
      signer_value,
      recipient_value,
      mint_value,
      True,
    )

  equal_share_mint.mint(redeemer, policy_id, tx)
}

test test_fail_odd_amount() {
  let policy_id = #"abcd1234"
  let asset_name = "MYTOKEN"
  let total_amount = 101
  let signer_hash = mock_pub_key_hash(1)
  let recipient_address = mock_pub_key_address(2, None)

  let redeemer = MintRedeemer { recipient_address, asset_name, total_amount }

  let mint_value = from_asset(policy_id, asset_name, total_amount)
  let signer_value =
    merge(from_lovelace(2_000_000), from_asset(policy_id, asset_name, 51))
  let recipient_value =
    merge(from_lovelace(2_000_000), from_asset(policy_id, asset_name, 50))

  let tx =
    build_test_transaction(
      signer_hash,
      recipient_address,
      signer_value,
      recipient_value,
      mint_value,
      True,
    )

  !equal_share_mint.mint(redeemer, policy_id, tx)
}

test test_fail_unequal_distribution() {
  let policy_id = #"abcd1234"
  let asset_name = "MYTOKEN"
  let total_amount = 100
  let signer_hash = mock_pub_key_hash(1)
  let recipient_address = mock_pub_key_address(2, None)

  let redeemer = MintRedeemer { recipient_address, asset_name, total_amount }

  let mint_value = from_asset(policy_id, asset_name, total_amount)
  let signer_value =
    merge(from_lovelace(2_000_000), from_asset(policy_id, asset_name, 70))
  let recipient_value =
    merge(from_lovelace(2_000_000), from_asset(policy_id, asset_name, 30))

  let tx =
    build_test_transaction(
      signer_hash,
      recipient_address,
      signer_value,
      recipient_value,
      mint_value,
      True,
    )

  !equal_share_mint.mint(redeemer, policy_id, tx)
}

test test_fail_no_signature() {
  let policy_id = #"abcd1234"
  let asset_name = "MYTOKEN"
  let total_amount = 100
  let recipient_address = mock_pub_key_address(2, None)

  let redeemer = MintRedeemer { recipient_address, asset_name, total_amount }

  let mint_value = from_asset(policy_id, asset_name, total_amount)
  let signer_value =
    merge(from_lovelace(2_000_000), from_asset(policy_id, asset_name, 50))
  let recipient_value =
    merge(from_lovelace(2_000_000), from_asset(policy_id, asset_name, 50))

  let tx =
    build_test_transaction(
      mock_pub_key_hash(1),
      recipient_address,
      signer_value,
      recipient_value,
      mint_value,
      False,
    )

  // No signature
  !equal_share_mint.mint(redeemer, policy_id, tx)
}

test test_fail_wrong_mint_amount() {
  let policy_id = #"abcd1234"
  let asset_name = "MYTOKEN"
  let total_amount = 100
  let signer_hash = mock_pub_key_hash(1)
  let recipient_address = mock_pub_key_address(2, None)

  let redeemer = MintRedeemer { recipient_address, asset_name, total_amount }

  let wrong_mint_value = from_asset(policy_id, asset_name, 200)
  let signer_value =
    merge(from_lovelace(2_000_000), from_asset(policy_id, asset_name, 50))
  let recipient_value =
    merge(from_lovelace(2_000_000), from_asset(policy_id, asset_name, 50))

  let tx =
    build_test_transaction(
      signer_hash,
      recipient_address,
      signer_value,
      recipient_value,
      wrong_mint_value,
      True,
    )

  !equal_share_mint.mint(redeemer, policy_id, tx)
}

test test_multiple_outputs_to_same_address() {
  let policy_id = #"abcd1234"
  let asset_name = "MYTOKEN"
  let total_amount = 100
  let signer_hash = mock_pub_key_hash(1)
  let recipient_address = mock_pub_key_address(2, None)
  let signer_address = mock_pub_key_address(1, None)

  let redeemer = MintRedeemer { recipient_address, asset_name, total_amount }

  let mint_value = from_asset(policy_id, asset_name, total_amount)
  let signer_value1 =
    merge(from_lovelace(1_000_000), from_asset(policy_id, asset_name, 30))
  let signer_value2 =
    merge(from_lovelace(1_000_000), from_asset(policy_id, asset_name, 20))
  let recipient_value =
    merge(from_lovelace(2_000_000), from_asset(policy_id, asset_name, 50))

  let tx =
    Transaction {
      ..placeholder,
      outputs: [
        Output {
          address: signer_address,
          value: signer_value1,
          datum: NoDatum,
          reference_script: None,
        },
        Output {
          address: signer_address,
          value: signer_value2,
          datum: NoDatum,
          reference_script: None,
        },
        Output {
          address: recipient_address,
          value: recipient_value,
          datum: NoDatum,
          reference_script: None,
        },
      ],
      extra_signatories: [signer_hash],
      mint: mint_value,
    }

  equal_share_mint.mint(redeemer, policy_id, tx)
}

test test_zero_amount_mint() {
  let policy_id = #"abcd1234"
  let asset_name = "MYTOKEN"
  let total_amount = 0
  let signer_hash = mock_pub_key_hash(1)
  let recipient_address = mock_pub_key_address(2, None)

  let redeemer = MintRedeemer { recipient_address, asset_name, total_amount }

  let mint_value = from_asset(policy_id, asset_name, 0)
  let signer_value = from_lovelace(2_000_000)
  let recipient_value = from_lovelace(2_000_000)

  let tx =
    build_test_transaction(
      signer_hash,
      recipient_address,
      signer_value,
      recipient_value,
      mint_value,
      True,
    )

  equal_share_mint.mint(redeemer, policy_id, tx)
}
