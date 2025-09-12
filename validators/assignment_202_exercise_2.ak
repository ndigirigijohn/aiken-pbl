use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Address, VerificationKey}
use cardano/assets.{Value, flatten, from_asset, merge, zero}
use cardano/transaction.{InlineDatum, Output, OutputReference, Transaction}

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
          // Find corresponding amounts in each wallet's outputs
          expect Some((_, _, amount_a)) =
            list.find(
              wallet_a_assets,
              fn(asset) {
                let (pid, name, _) = asset
                pid == policy_id && name == asset_name
              },
            )
          expect Some((_, _, amount_b)) =
            list.find(
              wallet_b_assets,
              fn(asset) {
                let (pid, name, _) = asset
                pid == policy_id && name == asset_name
              },
            )
          // Check if amounts are split correctly
          // For even amounts: each wallet gets exactly half
          // For odd amounts: one wallet gets (n+1)/2, other gets n/2
          let half = total_amount / 2
          let remainder = total_amount % 2
          or {
            and {
              amount_a == half,
              amount_b == half + remainder,
            },
            and {
              amount_a == half + remainder,
              amount_b == half,
            },
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
