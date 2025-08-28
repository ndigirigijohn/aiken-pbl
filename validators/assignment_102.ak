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
