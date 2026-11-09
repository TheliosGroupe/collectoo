
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "public": {
          Tables: {
            "account": {
                  Row: {
                    "boarding_batch_id": string | null,"claim_type_code": string,"client_organization_id": string,"contract_date": string | null,"created_at": string,"currency": string,"external_ref": string,"id": string,"legal_regime": string,"organization_id": string,"portfolio_id": string,"seller_limitation_date": string | null,"source_attributes": NonNullable<Json>,"status": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "boarding_batch_id"?: string | null,"claim_type_code": string,"client_organization_id": string,"contract_date"?: string | null,"created_at"?: string,"currency"?: string,"external_ref": string,"id"?: string,"legal_regime": string,"organization_id": string,"portfolio_id": string,"seller_limitation_date"?: string | null,"source_attributes"?: NonNullable<Json>,"status"?: string,"updated_at"?: string
                  }
                  Update: {
                    "boarding_batch_id"?: string | null,"claim_type_code"?: string,"client_organization_id"?: string,"contract_date"?: string | null,"created_at"?: string,"currency"?: string,"external_ref"?: string,"id"?: string,"legal_regime"?: string,"organization_id"?: string,"portfolio_id"?: string,"seller_limitation_date"?: string | null,"source_attributes"?: NonNullable<Json>,"status"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "account_boarding_batch_fk"
      columns: ["boarding_batch_id"]
isOneToOne: false
      referencedRelation: "boarding_batch"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "account_claim_type_code_fkey"
      columns: ["claim_type_code"]
isOneToOne: false
      referencedRelation: "claim_type"
      referencedColumns: ["code"]
    },{
      foreignKeyName: "account_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "account_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "account_portfolio_id_fkey"
      columns: ["portfolio_id"]
isOneToOne: false
      referencedRelation: "portfolio"
      referencedColumns: ["id"]
    }
                  ]
                },"account_hold": {
                  Row: {
                    "account_id": string,"client_organization_id": string,"created_at": string,"decided_by": string | null,"end_reason": string | null,"ended_at": string | null,"ended_by": string | null,"evidence_document_id": string | null,"id": string,"kind": string,"legal_basis": string | null,"organization_id": string,"portfolio_id": string,"reason": string,"scope": (string)[],"started_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id": string,"client_organization_id": string,"created_at"?: string,"decided_by"?: string | null,"end_reason"?: string | null,"ended_at"?: string | null,"ended_by"?: string | null,"evidence_document_id"?: string | null,"id"?: string,"kind": string,"legal_basis"?: string | null,"organization_id": string,"portfolio_id": string,"reason": string,"scope": (string)[],"started_at"?: string
                  }
                  Update: {
                    "account_id"?: string,"client_organization_id"?: string,"created_at"?: string,"decided_by"?: string | null,"end_reason"?: string | null,"ended_at"?: string | null,"ended_by"?: string | null,"evidence_document_id"?: string | null,"id"?: string,"kind"?: string,"legal_basis"?: string | null,"organization_id"?: string,"portfolio_id"?: string,"reason"?: string,"scope"?: (string)[],"started_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "account_hold_account_fk"
      columns: ["account_id","organization_id","client_organization_id","portfolio_id"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id","organization_id","client_organization_id","portfolio_id"]
    },{
      foreignKeyName: "account_hold_decided_by_fkey"
      columns: ["decided_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "account_hold_ended_by_fkey"
      columns: ["ended_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "account_hold_evidence_document_id_fkey"
      columns: ["evidence_document_id"]
isOneToOne: false
      referencedRelation: "document"
      referencedColumns: ["id"]
    }
                  ]
                },"account_party": {
                  Row: {
                    "account_id": string,"cap_minor": number | null,"capacity": string,"created_at": string,"liability": string,"party_id": string,"role": string
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id": string,"cap_minor"?: number | null,"capacity": string,"created_at"?: string,"liability"?: string,"party_id": string,"role": string
                  }
                  Update: {
                    "account_id"?: string,"cap_minor"?: number | null,"capacity"?: string,"created_at"?: string,"liability"?: string,"party_id"?: string,"role"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "account_party_account_id_fkey"
      columns: ["account_id"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "account_party_party_id_fkey"
      columns: ["party_id"]
isOneToOne: false
      referencedRelation: "party"
      referencedColumns: ["id"]
    }
                  ]
                },"app_user": {
                  Row: {
                    "created_at": string,"display_name": string | null,"email": string | null,"id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"display_name"?: string | null,"email"?: string | null,"id": string,"updated_at"?: string
                  }
                  Update: {
                    "created_at"?: string,"display_name"?: string | null,"email"?: string | null,"id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    
                  ]
                },"bank_account": {
                  Row: {
                    "bic": string | null,"closed_on": string | null,"closed_reason": string | null,"created_at": string,"created_by": string | null,"csv_profile": Json | null,"currency": string,"feed": string,"iban": string,"id": string,"label": string,"opened_on": string,"organization_id": string,"purpose": string,"status": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "bic"?: string | null,"closed_on"?: string | null,"closed_reason"?: string | null,"created_at"?: string,"created_by"?: string | null,"csv_profile"?: Json | null,"currency": string,"feed": string,"iban": string,"id"?: string,"label": string,"opened_on": string,"organization_id": string,"purpose"?: string,"status"?: string,"updated_at"?: string
                  }
                  Update: {
                    "bic"?: string | null,"closed_on"?: string | null,"closed_reason"?: string | null,"created_at"?: string,"created_by"?: string | null,"csv_profile"?: Json | null,"currency"?: string,"feed"?: string,"iban"?: string,"id"?: string,"label"?: string,"opened_on"?: string,"organization_id"?: string,"purpose"?: string,"status"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "bank_account_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bank_account_currency_fkey"
      columns: ["currency"]
isOneToOne: false
      referencedRelation: "currency"
      referencedColumns: ["code"]
    },{
      foreignKeyName: "bank_account_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    }
                  ]
                },"bank_statement": {
                  Row: {
                    "bank_account_id": string,"bank_check": Json | null,"closing_booked_minor": number | null,"counts": Json | null,"created_at": string,"created_by": string | null,"currency": string,"electronic_seq_no": number | null,"error": string | null,"error_code": string | null,"file_name": string,"file_sha256": string,"finished_at": string | null,"format": string,"format_version": string | null,"from_date": string | null,"id": string,"idempotency_key": string | null,"opening_booked_minor": number | null,"organization_id": string,"sections": Json | null,"size_bytes": number,"status": string,"stmt_id": string | null,"storage_bucket": string,"storage_path": string,"to_date": string | null,"updated_at": string,"uploaded_at": string | null,"warnings": NonNullable<Json>
                  }
                  ComputedFields: never
                  Insert: {
                    "bank_account_id": string,"bank_check"?: Json | null,"closing_booked_minor"?: number | null,"counts"?: Json | null,"created_at"?: string,"created_by"?: string | null,"currency": string,"electronic_seq_no"?: number | null,"error"?: string | null,"error_code"?: string | null,"file_name": string,"file_sha256": string,"finished_at"?: string | null,"format": string,"format_version"?: string | null,"from_date"?: string | null,"id"?: string,"idempotency_key"?: string | null,"opening_booked_minor"?: number | null,"organization_id": string,"sections"?: Json | null,"size_bytes": number,"status"?: string,"stmt_id"?: string | null,"storage_bucket"?: string,"storage_path": string,"to_date"?: string | null,"updated_at"?: string,"uploaded_at"?: string | null,"warnings"?: NonNullable<Json>
                  }
                  Update: {
                    "bank_account_id"?: string,"bank_check"?: Json | null,"closing_booked_minor"?: number | null,"counts"?: Json | null,"created_at"?: string,"created_by"?: string | null,"currency"?: string,"electronic_seq_no"?: number | null,"error"?: string | null,"error_code"?: string | null,"file_name"?: string,"file_sha256"?: string,"finished_at"?: string | null,"format"?: string,"format_version"?: string | null,"from_date"?: string | null,"id"?: string,"idempotency_key"?: string | null,"opening_booked_minor"?: number | null,"organization_id"?: string,"sections"?: Json | null,"size_bytes"?: number,"status"?: string,"stmt_id"?: string | null,"storage_bucket"?: string,"storage_path"?: string,"to_date"?: string | null,"updated_at"?: string,"uploaded_at"?: string | null,"warnings"?: NonNullable<Json>
                  }
                  Relationships: [
                    {
      foreignKeyName: "bank_statement_bank_fk"
      columns: ["bank_account_id","organization_id","currency"]
isOneToOne: false
      referencedRelation: "bank_account"
      referencedColumns: ["id","organization_id","currency"]
    },{
      foreignKeyName: "bank_statement_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bank_statement_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    }
                  ]
                },"bank_transaction": {
                  Row: {
                    "acct_svcr_ref": string | null,"amount_minor": number,"bank_account_id": string,"bank_tx_code": string | null,"batch_entry_ref": string | null,"booking_date": string,"counterparty_iban": string | null,"counterparty_name": string | null,"created_at": string,"creditor_reference": string | null,"currency": string,"dedup_key": string,"direction": string,"end_to_end_id": string | null,"entry_ref": string | null,"id": string,"kind": string,"line_no": number,"mandate_ref": string | null,"organization_id": string,"original_end_to_end_id": string | null,"remittance_text": string | null,"return_reason": string | null,"reversal_indicator": boolean,"statement_id": string,"tx_id": string | null,"ultimate_counterparty_name": string | null,"value_date": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "acct_svcr_ref"?: string | null,"amount_minor": number,"bank_account_id": string,"bank_tx_code"?: string | null,"batch_entry_ref"?: string | null,"booking_date": string,"counterparty_iban"?: string | null,"counterparty_name"?: string | null,"created_at"?: string,"creditor_reference"?: string | null,"currency": string,"dedup_key": string,"direction": string,"end_to_end_id"?: string | null,"entry_ref"?: string | null,"id"?: string,"kind": string,"line_no": number,"mandate_ref"?: string | null,"organization_id": string,"original_end_to_end_id"?: string | null,"remittance_text"?: string | null,"return_reason"?: string | null,"reversal_indicator"?: boolean,"statement_id": string,"tx_id"?: string | null,"ultimate_counterparty_name"?: string | null,"value_date"?: string | null
                  }
                  Update: {
                    "acct_svcr_ref"?: string | null,"amount_minor"?: number,"bank_account_id"?: string,"bank_tx_code"?: string | null,"batch_entry_ref"?: string | null,"booking_date"?: string,"counterparty_iban"?: string | null,"counterparty_name"?: string | null,"created_at"?: string,"creditor_reference"?: string | null,"currency"?: string,"dedup_key"?: string,"direction"?: string,"end_to_end_id"?: string | null,"entry_ref"?: string | null,"id"?: string,"kind"?: string,"line_no"?: number,"mandate_ref"?: string | null,"organization_id"?: string,"original_end_to_end_id"?: string | null,"remittance_text"?: string | null,"return_reason"?: string | null,"reversal_indicator"?: boolean,"statement_id"?: string,"tx_id"?: string | null,"ultimate_counterparty_name"?: string | null,"value_date"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "bank_transaction_statement_fk"
      columns: ["statement_id","organization_id","bank_account_id","currency"]
isOneToOne: false
      referencedRelation: "bank_statement"
      referencedColumns: ["id","organization_id","bank_account_id","currency"]
    }
                  ]
                },"boarding_batch": {
                  Row: {
                    "art4_exemptions": NonNullable<Json>,"claim_type_spec_version": number | null,"client_organization_id": string,"commit_override_reason": string | null,"commit_requested_at": string | null,"commit_requested_by": string | null,"confirm_requested_at": string | null,"confirm_requested_by": string | null,"conformance": string,"created_at": string,"created_by": string | null,"cut_off_date": string | null,"dq_report": Json | null,"failed_job": Json | null,"id": string,"join_keys": NonNullable<Json>,"opening_plan": Json | null,"opening_summary": Json | null,"organization_id": string,"portfolio_id": string,"seller_control_totals": NonNullable<Json>,"staging_digest": Json | null,"status": string,"transform_spec_version": number | null,"updated_at": string,"validation_spec_version": number | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "art4_exemptions"?: NonNullable<Json>,"claim_type_spec_version"?: number | null,"client_organization_id": string,"commit_override_reason"?: string | null,"commit_requested_at"?: string | null,"commit_requested_by"?: string | null,"confirm_requested_at"?: string | null,"confirm_requested_by"?: string | null,"conformance"?: string,"created_at"?: string,"created_by"?: string | null,"cut_off_date"?: string | null,"dq_report"?: Json | null,"failed_job"?: Json | null,"id"?: string,"join_keys"?: NonNullable<Json>,"opening_plan"?: Json | null,"opening_summary"?: Json | null,"organization_id": string,"portfolio_id": string,"seller_control_totals"?: NonNullable<Json>,"staging_digest"?: Json | null,"status"?: string,"transform_spec_version"?: number | null,"updated_at"?: string,"validation_spec_version"?: number | null,"version": number
                  }
                  Update: {
                    "art4_exemptions"?: NonNullable<Json>,"claim_type_spec_version"?: number | null,"client_organization_id"?: string,"commit_override_reason"?: string | null,"commit_requested_at"?: string | null,"commit_requested_by"?: string | null,"confirm_requested_at"?: string | null,"confirm_requested_by"?: string | null,"conformance"?: string,"created_at"?: string,"created_by"?: string | null,"cut_off_date"?: string | null,"dq_report"?: Json | null,"failed_job"?: Json | null,"id"?: string,"join_keys"?: NonNullable<Json>,"opening_plan"?: Json | null,"opening_summary"?: Json | null,"organization_id"?: string,"portfolio_id"?: string,"seller_control_totals"?: NonNullable<Json>,"staging_digest"?: Json | null,"status"?: string,"transform_spec_version"?: number | null,"updated_at"?: string,"validation_spec_version"?: number | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "boarding_batch_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "boarding_batch_commit_requested_by_fkey"
      columns: ["commit_requested_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "boarding_batch_confirm_requested_by_fkey"
      columns: ["confirm_requested_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "boarding_batch_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "boarding_batch_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "boarding_batch_portfolio_id_fkey"
      columns: ["portfolio_id"]
isOneToOne: false
      referencedRelation: "portfolio"
      referencedColumns: ["id"]
    }
                  ]
                },"boarding_event": {
                  Row: {
                    "actor_id": string | null,"actor_label": string | null,"at": string,"batch_id": string,"from_status": string | null,"id": number,"reason": string | null,"to_status": string
                  }
                  ComputedFields: never
                  Insert: {
                    "actor_id"?: string | null,"actor_label"?: string | null,"at"?: string,"batch_id": string,"from_status"?: string | null,"id"?: never,"reason"?: string | null,"to_status": string
                  }
                  Update: {
                    "actor_id"?: string | null,"actor_label"?: string | null,"at"?: string,"batch_id"?: string,"from_status"?: string | null,"id"?: never,"reason"?: string | null,"to_status"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "boarding_event_batch_id_fkey"
      columns: ["batch_id"]
isOneToOne: false
      referencedRelation: "boarding_batch"
      referencedColumns: ["id"]
    }
                  ]
                },"boarding_file": {
                  Row: {
                    "batch_id": string,"created_at": string,"duplicate_of_file_id": string | null,"error": string | null,"file_name": string,"format": string,"id": string,"profile": Json | null,"role": string | null,"row_count": number | null,"sha256": string,"size_bytes": number,"status": string,"storage_bucket": string,"storage_path": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "batch_id": string,"created_at"?: string,"duplicate_of_file_id"?: string | null,"error"?: string | null,"file_name": string,"format": string,"id"?: string,"profile"?: Json | null,"role"?: string | null,"row_count"?: number | null,"sha256": string,"size_bytes": number,"status"?: string,"storage_bucket"?: string,"storage_path": string,"updated_at"?: string
                  }
                  Update: {
                    "batch_id"?: string,"created_at"?: string,"duplicate_of_file_id"?: string | null,"error"?: string | null,"file_name"?: string,"format"?: string,"id"?: string,"profile"?: Json | null,"role"?: string | null,"row_count"?: number | null,"sha256"?: string,"size_bytes"?: number,"status"?: string,"storage_bucket"?: string,"storage_path"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "boarding_file_batch_id_fkey"
      columns: ["batch_id"]
isOneToOne: false
      referencedRelation: "boarding_batch"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "boarding_file_duplicate_of_file_id_fkey"
      columns: ["duplicate_of_file_id"]
isOneToOne: false
      referencedRelation: "boarding_file"
      referencedColumns: ["id"]
    }
                  ]
                },"claim_item": {
                  Row: {
                    "account_id": string,"created_at": string,"currency": string,"due_date": string | null,"id": string,"issue_date": string | null,"kind": string,"original_minor": number,"ref": string,"seller_paid_minor": number
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id": string,"created_at"?: string,"currency"?: string,"due_date"?: string | null,"id"?: string,"issue_date"?: string | null,"kind": string,"original_minor": number,"ref": string,"seller_paid_minor"?: number
                  }
                  Update: {
                    "account_id"?: string,"created_at"?: string,"currency"?: string,"due_date"?: string | null,"id"?: string,"issue_date"?: string | null,"kind"?: string,"original_minor"?: number,"ref"?: string,"seller_paid_minor"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "claim_item_account_id_fkey"
      columns: ["account_id"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id"]
    }
                  ]
                },"claim_ownership_period": {
                  Row: {
                    "account_id": string,"created_at": string,"id": string,"mandate_type": string,"owner_organization_id": string,"servicer_organization_id": string,"valid_from": string,"valid_to": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id": string,"created_at"?: string,"id"?: string,"mandate_type": string,"owner_organization_id": string,"servicer_organization_id": string,"valid_from": string,"valid_to"?: string | null
                  }
                  Update: {
                    "account_id"?: string,"created_at"?: string,"id"?: string,"mandate_type"?: string,"owner_organization_id"?: string,"servicer_organization_id"?: string,"valid_from"?: string,"valid_to"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "claim_ownership_period_account_id_fkey"
      columns: ["account_id"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "claim_ownership_period_owner_organization_id_fkey"
      columns: ["owner_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "claim_ownership_period_servicer_organization_id_fkey"
      columns: ["servicer_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    }
                  ]
                },"claim_type": {
                  Row: {
                    "code": string,"family": string,"label_fr": string
                  }
                  ComputedFields: never
                  Insert: {
                    "code": string,"family": string,"label_fr": string
                  }
                  Update: {
                    "code"?: string,"family"?: string,"label_fr"?: string
                  }
                  Relationships: [
                    
                  ]
                },"contact_consent": {
                  Row: {
                    "basis": string,"channel": string,"contact_point_id": string,"created_at": string,"evidence_document_id": string | null,"given_at": string,"id": string,"purpose": string,"withdrawn_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "basis": string,"channel": string,"contact_point_id": string,"created_at"?: string,"evidence_document_id"?: string | null,"given_at": string,"id"?: string,"purpose": string,"withdrawn_at"?: string | null
                  }
                  Update: {
                    "basis"?: string,"channel"?: string,"contact_point_id"?: string,"created_at"?: string,"evidence_document_id"?: string | null,"given_at"?: string,"id"?: string,"purpose"?: string,"withdrawn_at"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "contact_consent_contact_point_id_fkey"
      columns: ["contact_point_id"]
isOneToOne: false
      referencedRelation: "contact_point"
      referencedColumns: ["id"]
    }
                  ]
                },"contact_point": {
                  Row: {
                    "created_at": string,"id": string,"party_id": string,"source": string,"status": string,"type": string,"updated_at": string,"valid_from": string,"valid_to": string | null,"value_normalised": string | null,"value_raw": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: string,"party_id": string,"source": string,"status"?: string,"type": string,"updated_at"?: string,"valid_from"?: string,"valid_to"?: string | null,"value_normalised"?: string | null,"value_raw": string
                  }
                  Update: {
                    "created_at"?: string,"id"?: string,"party_id"?: string,"source"?: string,"status"?: string,"type"?: string,"updated_at"?: string,"valid_from"?: string,"valid_to"?: string | null,"value_normalised"?: string | null,"value_raw"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "contact_point_party_id_fkey"
      columns: ["party_id"]
isOneToOne: false
      referencedRelation: "party"
      referencedColumns: ["id"]
    }
                  ]
                },"currency": {
                  Row: {
                    "code": string,"label_fr": string,"minor_exponent": number
                  }
                  ComputedFields: never
                  Insert: {
                    "code": string,"label_fr": string,"minor_exponent": number
                  }
                  Update: {
                    "code"?: string,"label_fr"?: string,"minor_exponent"?: number
                  }
                  Relationships: [
                    
                  ]
                },"document": {
                  Row: {
                    "account_id": string | null,"boarding_batch_id": string | null,"client_organization_id": string,"created_at": string,"file_name": string | null,"id": string,"kind": string,"mime_type": string,"organization_id": string,"party_id": string | null,"sha256": string,"storage_bucket": string,"storage_path": string
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id"?: string | null,"boarding_batch_id"?: string | null,"client_organization_id": string,"created_at"?: string,"file_name"?: string | null,"id"?: string,"kind": string,"mime_type": string,"organization_id": string,"party_id"?: string | null,"sha256": string,"storage_bucket"?: string,"storage_path": string
                  }
                  Update: {
                    "account_id"?: string | null,"boarding_batch_id"?: string | null,"client_organization_id"?: string,"created_at"?: string,"file_name"?: string | null,"id"?: string,"kind"?: string,"mime_type"?: string,"organization_id"?: string,"party_id"?: string | null,"sha256"?: string,"storage_bucket"?: string,"storage_path"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "document_account_id_fkey"
      columns: ["account_id"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "document_boarding_batch_id_fkey"
      columns: ["boarding_batch_id"]
isOneToOne: false
      referencedRelation: "boarding_batch"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "document_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "document_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "document_party_id_fkey"
      columns: ["party_id"]
isOneToOne: false
      referencedRelation: "party"
      referencedColumns: ["id"]
    }
                  ]
                },"ledger_account": {
                  Row: {
                    "account_id": string | null,"bank_account_id": string | null,"book": string,"claim_item_id": string | null,"client_organization_id": string | null,"component": string | null,"created_at": string,"currency": string,"id": string,"organization_id": string,"owner_organization_id": string | null,"portfolio_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id"?: string | null,"bank_account_id"?: string | null,"book": string,"claim_item_id"?: string | null,"client_organization_id"?: string | null,"component"?: string | null,"created_at"?: string,"currency": string,"id"?: string,"organization_id": string,"owner_organization_id"?: string | null,"portfolio_id"?: string | null
                  }
                  Update: {
                    "account_id"?: string | null,"bank_account_id"?: string | null,"book"?: string,"claim_item_id"?: string | null,"client_organization_id"?: string | null,"component"?: string | null,"created_at"?: string,"currency"?: string,"id"?: string,"organization_id"?: string,"owner_organization_id"?: string | null,"portfolio_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "ledger_account_bank_fk"
      columns: ["bank_account_id","organization_id","currency"]
isOneToOne: false
      referencedRelation: "bank_account"
      referencedColumns: ["id","organization_id","currency"]
    },{
      foreignKeyName: "ledger_account_claim_fk"
      columns: ["account_id","organization_id","client_organization_id","portfolio_id","currency"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id","organization_id","client_organization_id","portfolio_id","currency"]
    },{
      foreignKeyName: "ledger_account_item_fk"
      columns: ["claim_item_id","account_id"]
isOneToOne: false
      referencedRelation: "claim_item"
      referencedColumns: ["id","account_id"]
    }
                  ]
                },"ledger_book": {
                  Row: {
                    "account_number": string,"client_visible": boolean,"code": string,"dimension": string,"label_fr": string,"money_of": string,"normal_side": number
                  }
                  ComputedFields: never
                  Insert: {
                    "account_number": string,"client_visible": boolean,"code": string,"dimension": string,"label_fr": string,"money_of": string,"normal_side": number
                  }
                  Update: {
                    "account_number"?: string,"client_visible"?: boolean,"code"?: string,"dimension"?: string,"label_fr"?: string,"money_of"?: string,"normal_side"?: number
                  }
                  Relationships: [
                    
                  ]
                },"ledger_component": {
                  Row: {
                    "code": string,"eba_field": string | null,"family": string,"label_fr": string,"reference": string,"sort_order": number
                  }
                  ComputedFields: never
                  Insert: {
                    "code": string,"eba_field"?: string | null,"family": string,"label_fr": string,"reference": string,"sort_order": number
                  }
                  Update: {
                    "code"?: string,"eba_field"?: string | null,"family"?: string,"label_fr"?: string,"reference"?: string,"sort_order"?: number
                  }
                  Relationships: [
                    
                  ]
                },"ledger_entry": {
                  Row: {
                    "account_id": string | null,"actor_id": string | null,"actor_label": string | null,"boarding_batch_id": string | null,"client_organization_id": string | null,"effective_date": string,"engine_version": string | null,"entry_type": string,"id": string,"idempotency_key": string,"inputs_hash": string | null,"line_count": number,"organization_id": string,"payment_id": string | null,"portfolio_id": string | null,"posted_at": string,"reason": string | null,"request_hash": string,"reverses_entry_id": string | null,"rule_pack_version_id": string | null,"source_id": string | null,"source_type": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id"?: string | null,"actor_id"?: string | null,"actor_label"?: string | null,"boarding_batch_id"?: string | null,"client_organization_id"?: string | null,"effective_date": string,"engine_version"?: string | null,"entry_type": string,"id"?: string,"idempotency_key": string,"inputs_hash"?: string | null,"line_count": number,"organization_id": string,"payment_id"?: string | null,"portfolio_id"?: string | null,"posted_at"?: string,"reason"?: string | null,"request_hash": string,"reverses_entry_id"?: string | null,"rule_pack_version_id"?: string | null,"source_id"?: string | null,"source_type"?: string | null
                  }
                  Update: {
                    "account_id"?: string | null,"actor_id"?: string | null,"actor_label"?: string | null,"boarding_batch_id"?: string | null,"client_organization_id"?: string | null,"effective_date"?: string,"engine_version"?: string | null,"entry_type"?: string,"id"?: string,"idempotency_key"?: string,"inputs_hash"?: string | null,"line_count"?: number,"organization_id"?: string,"payment_id"?: string | null,"portfolio_id"?: string | null,"posted_at"?: string,"reason"?: string | null,"request_hash"?: string,"reverses_entry_id"?: string | null,"rule_pack_version_id"?: string | null,"source_id"?: string | null,"source_type"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "ledger_entry_account_id_fkey"
      columns: ["account_id"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "ledger_entry_boarding_batch_id_fkey"
      columns: ["boarding_batch_id"]
isOneToOne: false
      referencedRelation: "boarding_batch"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "ledger_entry_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "ledger_entry_entry_type_fkey"
      columns: ["entry_type"]
isOneToOne: false
      referencedRelation: "ledger_entry_type"
      referencedColumns: ["code"]
    },{
      foreignKeyName: "ledger_entry_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "ledger_entry_payment_id_fkey"
      columns: ["payment_id"]
isOneToOne: false
      referencedRelation: "payment"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "ledger_entry_portfolio_id_fkey"
      columns: ["portfolio_id"]
isOneToOne: false
      referencedRelation: "portfolio"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "ledger_entry_reverses_entry_id_fkey"
      columns: ["reverses_entry_id"]
isOneToOne: false
      referencedRelation: "ledger_entry"
      referencedColumns: ["id"]
    }
                  ]
                },"ledger_entry_type": {
                  Row: {
                    "allowed_books": (string)[] | null,"code": string,"label_fr": string,"requires_reason": boolean
                  }
                  ComputedFields: never
                  Insert: {
                    "allowed_books"?: (string)[] | null,"code": string,"label_fr": string,"requires_reason": boolean
                  }
                  Update: {
                    "allowed_books"?: (string)[] | null,"code"?: string,"label_fr"?: string,"requires_reason"?: boolean
                  }
                  Relationships: [
                    
                  ]
                },"ledger_posting": {
                  Row: {
                    "amount_minor": number,"currency": string,"effective_date": string,"entry_id": string,"ledger_account_id": string,"line_no": number
                  }
                  ComputedFields: never
                  Insert: {
                    "amount_minor": number,"currency": string,"effective_date": string,"entry_id": string,"ledger_account_id": string,"line_no": number
                  }
                  Update: {
                    "amount_minor"?: number,"currency"?: string,"effective_date"?: string,"entry_id"?: string,"ledger_account_id"?: string,"line_no"?: number
                  }
                  Relationships: [
                    
                  ]
                },"mandate": {
                  Row: {
                    "client_organization_id": string,"created_at": string,"id": string,"mandate_type": string,"organization_id": string,"reference": string,"signed_document_id": string | null,"signed_on": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "client_organization_id": string,"created_at"?: string,"id"?: string,"mandate_type": string,"organization_id": string,"reference": string,"signed_document_id"?: string | null,"signed_on": string,"updated_at"?: string
                  }
                  Update: {
                    "client_organization_id"?: string,"created_at"?: string,"id"?: string,"mandate_type"?: string,"organization_id"?: string,"reference"?: string,"signed_document_id"?: string | null,"signed_on"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "mandate_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "mandate_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    }
                  ]
                },"mandate_terms": {
                  Row: {
                    "commission_rate": number,"created_at": string,"id": string,"mandate_id": string,"plan_envelope": NonNullable<Json>,"remittance_max_days": number,"settlement_authority": NonNullable<Json>,"terms": NonNullable<Json>,"valid_from": string,"valid_to": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "commission_rate": number,"created_at"?: string,"id"?: string,"mandate_id": string,"plan_envelope"?: NonNullable<Json>,"remittance_max_days"?: number,"settlement_authority"?: NonNullable<Json>,"terms"?: NonNullable<Json>,"valid_from": string,"valid_to"?: string | null
                  }
                  Update: {
                    "commission_rate"?: number,"created_at"?: string,"id"?: string,"mandate_id"?: string,"plan_envelope"?: NonNullable<Json>,"remittance_max_days"?: number,"settlement_authority"?: NonNullable<Json>,"terms"?: NonNullable<Json>,"valid_from"?: string,"valid_to"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "mandate_terms_mandate_id_fkey"
      columns: ["mandate_id"]
isOneToOne: false
      referencedRelation: "mandate"
      referencedColumns: ["id"]
    }
                  ]
                },"mapping_profile": {
                  Row: {
                    "client_organization_id": string,"created_at": string,"created_by": string | null,"header_signature": string,"headers": NonNullable<Json>,"id": string,"mapping": NonNullable<Json>,"organization_id": string,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "client_organization_id": string,"created_at"?: string,"created_by"?: string | null,"header_signature": string,"headers": NonNullable<Json>,"id"?: string,"mapping": NonNullable<Json>,"organization_id": string,"version": number
                  }
                  Update: {
                    "client_organization_id"?: string,"created_at"?: string,"created_by"?: string | null,"header_signature"?: string,"headers"?: NonNullable<Json>,"id"?: string,"mapping"?: NonNullable<Json>,"organization_id"?: string,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "mapping_profile_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "mapping_profile_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "mapping_profile_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    }
                  ]
                },"mapping_proposal": {
                  Row: {
                    "batch_id": string,"confidence": number,"created_at": string,"file_id": string,"id": string,"needs_review": boolean,"origin": string,"rationale": string,"reviewed_by": string | null,"source_column": string,"status": string,"target": string | null,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "batch_id": string,"confidence": number,"created_at"?: string,"file_id": string,"id"?: string,"needs_review": boolean,"origin": string,"rationale": string,"reviewed_by"?: string | null,"source_column": string,"status"?: string,"target"?: string | null,"updated_at"?: string
                  }
                  Update: {
                    "batch_id"?: string,"confidence"?: number,"created_at"?: string,"file_id"?: string,"id"?: string,"needs_review"?: boolean,"origin"?: string,"rationale"?: string,"reviewed_by"?: string | null,"source_column"?: string,"status"?: string,"target"?: string | null,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "mapping_proposal_batch_id_fkey"
      columns: ["batch_id"]
isOneToOne: false
      referencedRelation: "boarding_batch"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "mapping_proposal_file_id_fkey"
      columns: ["file_id"]
isOneToOne: false
      referencedRelation: "boarding_file"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "mapping_proposal_reviewed_by_fkey"
      columns: ["reviewed_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    }
                  ]
                },"membership": {
                  Row: {
                    "created_at": string,"organization_id": string,"role": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"organization_id": string,"role": string,"user_id": string
                  }
                  Update: {
                    "created_at"?: string,"organization_id"?: string,"role"?: string,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "membership_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "membership_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    }
                  ]
                },"organization": {
                  Row: {
                    "created_at": string,"id": string,"kind": string,"legal_name": string,"servicer_organization_id": string | null,"siren": string | null,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: string,"kind": string,"legal_name": string,"servicer_organization_id"?: string | null,"siren"?: string | null,"updated_at"?: string
                  }
                  Update: {
                    "created_at"?: string,"id"?: string,"kind"?: string,"legal_name"?: string,"servicer_organization_id"?: string | null,"siren"?: string | null,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "organization_servicer_organization_id_fkey"
      columns: ["servicer_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    }
                  ]
                },"party": {
                  Row: {
                    "birth_date": string | null,"boarding_batch_id": string | null,"client_organization_id": string,"created_at": string,"display_name": string,"first_name": string | null,"id": string,"kind": string,"last_name": string | null,"legal_form": string | null,"organization_id": string,"seller_ref": string | null,"source_attributes": NonNullable<Json>,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "birth_date"?: string | null,"boarding_batch_id"?: string | null,"client_organization_id": string,"created_at"?: string,"display_name": string,"first_name"?: string | null,"id"?: string,"kind": string,"last_name"?: string | null,"legal_form"?: string | null,"organization_id": string,"seller_ref"?: string | null,"source_attributes"?: NonNullable<Json>,"updated_at"?: string
                  }
                  Update: {
                    "birth_date"?: string | null,"boarding_batch_id"?: string | null,"client_organization_id"?: string,"created_at"?: string,"display_name"?: string,"first_name"?: string | null,"id"?: string,"kind"?: string,"last_name"?: string | null,"legal_form"?: string | null,"organization_id"?: string,"seller_ref"?: string | null,"source_attributes"?: NonNullable<Json>,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "party_boarding_batch_id_fkey"
      columns: ["boarding_batch_id"]
isOneToOne: false
      referencedRelation: "boarding_batch"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "party_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "party_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    }
                  ]
                },"party_identifier": {
                  Row: {
                    "created_at": string,"id": string,"party_id": string,"scheme": string,"source": string,"value": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: string,"party_id": string,"scheme": string,"source"?: string,"value": string
                  }
                  Update: {
                    "created_at"?: string,"id"?: string,"party_id"?: string,"scheme"?: string,"source"?: string,"value"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "party_identifier_party_id_fkey"
      columns: ["party_id"]
isOneToOne: false
      referencedRelation: "party"
      referencedColumns: ["id"]
    }
                  ]
                },"payment": {
                  Row: {
                    "account_id": string | null,"amount_minor": number,"bank_account_id": string | null,"bank_transaction_id": string | null,"booking_date": string,"candidate_account_id": string | null,"channel": string,"client_organization_id": string | null,"created_at": string,"creditor_reference": string | null,"currency": string,"designation": Json | null,"end_to_end_id": string | null,"id": string,"match_method": string | null,"matched_at": string | null,"method": string,"organization_id": string,"payer_iban": string | null,"payer_name": string | null,"portfolio_id": string | null,"remittance_text": string | null,"review_reason": string | null,"status": string,"updated_at": string,"value_date": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id"?: string | null,"amount_minor": number,"bank_account_id"?: string | null,"bank_transaction_id"?: string | null,"booking_date": string,"candidate_account_id"?: string | null,"channel": string,"client_organization_id"?: string | null,"created_at"?: string,"creditor_reference"?: string | null,"currency": string,"designation"?: Json | null,"end_to_end_id"?: string | null,"id"?: string,"match_method"?: string | null,"matched_at"?: string | null,"method": string,"organization_id": string,"payer_iban"?: string | null,"payer_name"?: string | null,"portfolio_id"?: string | null,"remittance_text"?: string | null,"review_reason"?: string | null,"status"?: string,"updated_at"?: string,"value_date"?: string | null
                  }
                  Update: {
                    "account_id"?: string | null,"amount_minor"?: number,"bank_account_id"?: string | null,"bank_transaction_id"?: string | null,"booking_date"?: string,"candidate_account_id"?: string | null,"channel"?: string,"client_organization_id"?: string | null,"created_at"?: string,"creditor_reference"?: string | null,"currency"?: string,"designation"?: Json | null,"end_to_end_id"?: string | null,"id"?: string,"match_method"?: string | null,"matched_at"?: string | null,"method"?: string,"organization_id"?: string,"payer_iban"?: string | null,"payer_name"?: string | null,"portfolio_id"?: string | null,"remittance_text"?: string | null,"review_reason"?: string | null,"status"?: string,"updated_at"?: string,"value_date"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "payment_account_fk"
      columns: ["account_id","organization_id","client_organization_id","portfolio_id"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id","organization_id","client_organization_id","portfolio_id"]
    },{
      foreignKeyName: "payment_bank_fk"
      columns: ["bank_account_id","organization_id","currency"]
isOneToOne: false
      referencedRelation: "bank_account"
      referencedColumns: ["id","organization_id","currency"]
    },{
      foreignKeyName: "payment_bank_transaction_fk"
      columns: ["bank_transaction_id","organization_id","bank_account_id","currency","amount_minor","booking_date"]
isOneToOne: false
      referencedRelation: "bank_transaction"
      referencedColumns: ["id","organization_id","bank_account_id","currency","amount_minor","booking_date"]
    },{
      foreignKeyName: "payment_currency_fkey"
      columns: ["currency"]
isOneToOne: false
      referencedRelation: "currency"
      referencedColumns: ["code"]
    },{
      foreignKeyName: "payment_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    }
                  ]
                },"payment_match": {
                  Row: {
                    "account_id": string,"action": string,"client_organization_id": string,"decided_at": string,"decided_by": string | null,"designation": Json | null,"evidence": NonNullable<Json>,"iban_link": boolean,"id": string,"method": string,"organization_id": string,"payment_id": string,"portfolio_id": string,"reason": string | null,"review_reason": string | null,"rule": string | null,"rule_version": string,"trigger": string
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id": string,"action": string,"client_organization_id": string,"decided_at"?: string,"decided_by"?: string | null,"designation"?: Json | null,"evidence"?: NonNullable<Json>,"iban_link"?: boolean,"id"?: string,"method": string,"organization_id": string,"payment_id": string,"portfolio_id": string,"reason"?: string | null,"review_reason"?: string | null,"rule"?: string | null,"rule_version": string,"trigger": string
                  }
                  Update: {
                    "account_id"?: string,"action"?: string,"client_organization_id"?: string,"decided_at"?: string,"decided_by"?: string | null,"designation"?: Json | null,"evidence"?: NonNullable<Json>,"iban_link"?: boolean,"id"?: string,"method"?: string,"organization_id"?: string,"payment_id"?: string,"portfolio_id"?: string,"reason"?: string | null,"review_reason"?: string | null,"rule"?: string | null,"rule_version"?: string,"trigger"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "payment_match_account_fk"
      columns: ["account_id","organization_id","client_organization_id","portfolio_id"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id","organization_id","client_organization_id","portfolio_id"]
    },{
      foreignKeyName: "payment_match_decided_by_fkey"
      columns: ["decided_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payment_match_payment_fk"
      columns: ["payment_id","organization_id"]
isOneToOne: false
      referencedRelation: "payment"
      referencedColumns: ["id","organization_id"]
    }
                  ]
                },"payment_match_candidate": {
                  Row: {
                    "acceptable": boolean,"account_id": string,"created_at": string,"organization_id": string,"payment_id": string,"rank": number,"rule": string,"signals": NonNullable<Json>
                  }
                  ComputedFields: never
                  Insert: {
                    "acceptable"?: boolean,"account_id": string,"created_at"?: string,"organization_id": string,"payment_id": string,"rank": number,"rule": string,"signals"?: NonNullable<Json>
                  }
                  Update: {
                    "acceptable"?: boolean,"account_id"?: string,"created_at"?: string,"organization_id"?: string,"payment_id"?: string,"rank"?: number,"rule"?: string,"signals"?: NonNullable<Json>
                  }
                  Relationships: [
                    {
      foreignKeyName: "payment_match_candidate_account_id_fkey"
      columns: ["account_id"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payment_match_candidate_payment_id_fkey"
      columns: ["payment_id"]
isOneToOne: false
      referencedRelation: "payment"
      referencedColumns: ["id"]
    }
                  ]
                },"payment_reference": {
                  Row: {
                    "account_id": string,"client_organization_id": string,"created_at": string,"id": string,"organization_id": string,"portfolio_id": string,"retired_at": string | null,"retired_reason": string | null,"rf": string,"status": string
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id": string,"client_organization_id": string,"created_at"?: string,"id"?: string,"organization_id": string,"portfolio_id": string,"retired_at"?: string | null,"retired_reason"?: string | null,"rf": string,"status"?: string
                  }
                  Update: {
                    "account_id"?: string,"client_organization_id"?: string,"created_at"?: string,"id"?: string,"organization_id"?: string,"portfolio_id"?: string,"retired_at"?: string | null,"retired_reason"?: string | null,"rf"?: string,"status"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "payment_reference_account_fk"
      columns: ["account_id","organization_id","client_organization_id","portfolio_id"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id","organization_id","client_organization_id","portfolio_id"]
    }
                  ]
                },"portfolio": {
                  Row: {
                    "client_organization_id": string,"created_at": string,"default_claim_type": string | null,"id": string,"mandate_id": string | null,"name": string,"organization_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "client_organization_id": string,"created_at"?: string,"default_claim_type"?: string | null,"id"?: string,"mandate_id"?: string | null,"name": string,"organization_id": string,"updated_at"?: string
                  }
                  Update: {
                    "client_organization_id"?: string,"created_at"?: string,"default_claim_type"?: string | null,"id"?: string,"mandate_id"?: string | null,"name"?: string,"organization_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "portfolio_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "portfolio_mandate_id_fkey"
      columns: ["mandate_id"]
isOneToOne: false
      referencedRelation: "mandate"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "portfolio_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    }
                  ]
                },"portfolio_access": {
                  Row: {
                    "created_at": string,"portfolio_id": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"portfolio_id": string,"user_id": string
                  }
                  Update: {
                    "created_at"?: string,"portfolio_id"?: string,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "portfolio_access_portfolio_id_fkey"
      columns: ["portfolio_id"]
isOneToOne: false
      referencedRelation: "portfolio"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "portfolio_access_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    }
                  ]
                },"validation_issue": {
                  Row: {
                    "batch_id": string,"code": string,"created_at": string,"file_id": string,"id": number,"message": string,"raw_value": string | null,"row_number": number | null,"severity": string,"source_column": string | null,"target": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "batch_id": string,"code": string,"created_at"?: string,"file_id": string,"id"?: never,"message": string,"raw_value"?: string | null,"row_number"?: number | null,"severity": string,"source_column"?: string | null,"target"?: string | null
                  }
                  Update: {
                    "batch_id"?: string,"code"?: string,"created_at"?: string,"file_id"?: string,"id"?: never,"message"?: string,"raw_value"?: string | null,"row_number"?: number | null,"severity"?: string,"source_column"?: string | null,"target"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "validation_issue_batch_id_fkey"
      columns: ["batch_id"]
isOneToOne: false
      referencedRelation: "boarding_batch"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "validation_issue_file_id_fkey"
      columns: ["file_id"]
isOneToOne: false
      referencedRelation: "boarding_file"
      referencedColumns: ["id"]
    }
                  ]
                }
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "abandon_boarding_batch":
{ Args: { "p_batch_id": string,"p_reason": string }; Returns: undefined
                           },
"accept_suggestions":
{ Args: { "p_idempotency_key": string,"p_payment_ids": (string)[] }; Returns: Json
                           },
"account_balances":
{ Args: { "p_account_id": string,"p_as_of"?: string,"p_known_at"?: string }; Returns: {
              "balance_minor": number,"claim_item_id": string,"component": string,"currency": string
            }[]
                           },
"add_boarding_file":
{ Args: { "p_batch_id": string,"p_file_name": string,"p_sha256": string,"p_size_bytes": number }; Returns: Json
                           },
"approve_mapping":
{ Args: { "p_batch_id": string,"p_overrides"?: Json }; Returns: undefined
                           },
"assign_payment":
{ Args: { "p_designation": Json,"p_idempotency_key": string,"p_payment_id": string,"p_reason": string,"p_splits": Json }; Returns: Json
                           },
"client_money_balances":
{ Args: { "p_as_of"?: string,"p_client_organization_id": string,"p_known_at"?: string }; Returns: {
              "currency": string,"held_minor": number,"payable_minor": number,"unallocated_minor": number
            }[]
                           },
"close_bank_account":
{ Args: { "p_bank_account_id": string,"p_idempotency_key": string,"p_reason": string }; Returns: undefined
                           },
"commit_boarding_batch":
{ Args: { "p_batch_id": string,"p_override_reason"?: string }; Returns: undefined
                           },
"confirm_boarding_batch":
{ Args: { "p_batch_id": string }; Returns: undefined
                           },
"create_boarding_batch":
{ Args: { "p_conformance"?: string,"p_cut_off_date"?: string,"p_idempotency_key": string,"p_portfolio_id": string }; Returns: string
                           },
"create_portfolio":
{ Args: { "p_client_organization_id": string,"p_default_claim_type"?: string,"p_idempotency_key": string,"p_name": string }; Returns: string
                           },
"create_statement_upload":
{ Args: { "p_bank_account_id": string,"p_file_name": string,"p_idempotency_key": string,"p_sha256": string,"p_size_bytes": number }; Returns: Json
                           },
"custom_access_token_hook":
{ Args: { "event": Json }; Returns: Json
                           },
"ledger_balance":
{ Args: { "p_as_of"?: string,"p_known_at"?: string,"p_ledger_account_id": string }; Returns: number
                           },
"lift_account_hold":
{ Args: { "p_hold_id": string,"p_idempotency_key": string,"p_reason": string }; Returns: undefined
                           },
"match_queue_accounts":
{ Args: { "p_account_ids": (string)[] }; Returns: {
              "account_id": string,"balance_minor": string,"client_name": string,"currency": string,"debtor_name": string,"external_ref": string,"pending_minor": string,"rf": string,"status": string
            }[]
                           },
"place_account_hold":
{ Args: { "p_account_id": string,"p_evidence_document_id": string,"p_idempotency_key": string,"p_kind": string,"p_legal_basis": string,"p_reason": string }; Returns: string
                           },
"register_bank_account":
{ Args: { "p_bic"?: string,"p_currency": string,"p_feed": string,"p_iban": string,"p_idempotency_key": string,"p_label": string,"p_opened_on"?: string,"p_organization_id": string }; Returns: string
                           },
"retire_payment_reference":
{ Args: { "p_idempotency_key": string,"p_reason": string,"p_reference_id": string }; Returns: string
                           },
"rollback_boarding_batch":
{ Args: { "p_batch_id": string,"p_reason": string }; Returns: undefined
                           },
"search_payment_files":
{ Args: { "p_payment_id": string,"p_query": string }; Returns: {
              "account_id": string,"balance_minor": string,"client_name": string,"currency": string,"debtor_name": string,"external_ref": string,"found_by": string,"pending_minor": string,"rf": string,"status": string
            }[]
                           },
"set_control_totals":
{ Args: { "p_batch_id": string,"p_rows": number,"p_total_minor": number }; Returns: undefined
                           },
"statement_match_counts":
{ Args: { "p_statement_ids": (string)[] }; Returns: {
              "automatic": number,"payments": number,"statement_id": string,"to_review": number
            }[]
                           },
"submit_boarding_batch":
{ Args: { "p_batch_id": string }; Returns: number
                           },
"submit_statement_import":
{ Args: { "p_idempotency_key": string,"p_statement_id": string }; Returns: string
                           },
"unassign_payment":
{ Args: { "p_idempotency_key": string,"p_payment_id": string,"p_reason": string }; Returns: Json
                           }
          }
          Enums: {
            [_ in never]: never
          }
          CompositeTypes: {
            [_ in never]: never
          }
        }
}

type DatabaseWithoutInternals = Omit<Database, '__InternalSupabase'>

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
  ? (DefaultSchema["Tables"] & DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
      Row: infer R
    }
    ? R
    : never
  : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Insert: infer I
    }
    ? I
    : never
  : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Update: infer U
    }
    ? U
    : never
  : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never
> = DefaultSchemaEnumNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
  ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
  : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never
> = PublicCompositeTypeNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
  ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
  : never

export const Constants = {
  "public": {
          Enums: {
            
          }
        }
} as const
