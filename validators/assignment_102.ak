use cardano/transaction.{OutputReference, Transaction}

// Custom Datum Type - represents the "lock configuration"
pub type CustomDatum {
  SecretMessage { secret: ByteArray, owner: ByteArray, amount_locked: Int }
  PublicInfo { public_message: ByteArray, created_at: Int }
  EmptyDatum
}

// Custom Redeemer Type - represents the "key" to unlock
pub type CustomRedeemer {
  UnlockWithSecret { provided_secret: ByteArray, signature_required: Bool }
  PublicAccess { reason: ByteArray }
  AdminOverride { admin_signature: ByteArray }
  EmergencyUnlock
}

validator custom_spending_validator {
  spend(
    datum_opt: Option<CustomDatum>,
    redeemer: CustomRedeemer,
    _input: OutputReference,
    _tx: Transaction,
  ) {
    // First, ensure we have a datum (reject if None)
    expect Some(datum) = datum_opt
    // Now validate based on both datum and redeemer types
    when datum is {
      SecretMessage { secret, owner: _, amount_locked } ->
        when redeemer is {
          UnlockWithSecret { provided_secret, signature_required: _ } ->
            // Secret must match and amount must be positive
            provided_secret == secret && amount_locked > 0
          AdminOverride { admin_signature: _ } ->
            // Admin can unlock if amount is reasonable
            amount_locked <= 1000000
          // Max 1 ADA
          EmergencyUnlock ->
            // Emergency unlock only for small amounts
            amount_locked <= 100000
          // Max 0.1 ADA
          _ -> False
        }
      // Other redeemers don't work
      PublicInfo { public_message: _, created_at } ->
        when redeemer is {
          PublicAccess { reason } ->
            // Must provide a reason and data must be old enough
            reason != "" && created_at < 1000000
          AdminOverride { admin_signature: _ } -> True
          _ -> False
        }
      EmptyDatum ->
        when redeemer is {
          EmergencyUnlock -> True
          PublicAccess { reason: _ } -> True
          _ -> False
        }
    }
  }

  else(_) {
    fail
  }
}
