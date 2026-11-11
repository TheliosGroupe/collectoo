
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
                },"allocation_policy": {
                  Row: {
                    "accessory_rank": string,"client_organization_id": string | null,"created_at": string,"created_by": string | null,"effective_from": string,"id": string,"organization_id": string,"portfolio_id": string | null,"reason": string,"unclassified": string,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "accessory_rank": string,"client_organization_id"?: string | null,"created_at"?: string,"created_by"?: string | null,"effective_from": string,"id"?: string,"organization_id": string,"portfolio_id"?: string | null,"reason": string,"unclassified": string,"version": number
                  }
                  Update: {
                    "accessory_rank"?: string,"client_organization_id"?: string | null,"created_at"?: string,"created_by"?: string | null,"effective_from"?: string,"id"?: string,"organization_id"?: string,"portfolio_id"?: string | null,"reason"?: string,"unclassified"?: string,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "allocation_policy_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "allocation_policy_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "allocation_policy_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "allocation_policy_portfolio_id_fkey"
      columns: ["portfolio_id"]
isOneToOne: false
      referencedRelation: "portfolio"
      referencedColumns: ["id"]
    }
                  ]
                },"allocation_run": {
                  Row: {
                    "finished_at": string | null,"id": string,"organization_id": string,"started_at": string,"summary": NonNullable<Json>,"trigger": string
                  }
                  ComputedFields: never
                  Insert: {
                    "finished_at"?: string | null,"id"?: string,"organization_id": string,"started_at"?: string,"summary"?: NonNullable<Json>,"trigger": string
                  }
                  Update: {
                    "finished_at"?: string | null,"id"?: string,"organization_id"?: string,"started_at"?: string,"summary"?: NonNullable<Json>,"trigger"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "allocation_run_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
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
                    "bic": string | null,"closed_on": string | null,"closed_reason": string | null,"created_at": string,"created_by": string | null,"csv_profile": Json | null,"currency": string,"feed": string | null,"iban": string,"id": string,"label": string,"opened_on": string,"organization_id": string,"pain_version": string,"purpose": string,"status": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "bic"?: string | null,"closed_on"?: string | null,"closed_reason"?: string | null,"created_at"?: string,"created_by"?: string | null,"csv_profile"?: Json | null,"currency": string,"feed"?: string | null,"iban": string,"id"?: string,"label": string,"opened_on": string,"organization_id": string,"pain_version"?: string,"purpose"?: string,"status"?: string,"updated_at"?: string
                  }
                  Update: {
                    "bic"?: string | null,"closed_on"?: string | null,"closed_reason"?: string | null,"created_at"?: string,"created_by"?: string | null,"csv_profile"?: Json | null,"currency"?: string,"feed"?: string | null,"iban"?: string,"id"?: string,"label"?: string,"opened_on"?: string,"organization_id"?: string,"pain_version"?: string,"purpose"?: string,"status"?: string,"updated_at"?: string
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
                },"bank_debit_link": {
                  Row: {
                    "bank_account_id": string,"bank_transaction_id": string,"cash_entry_id": string | null,"decided_at": string,"decided_by": string | null,"kind": string,"method": string,"organization_id": string,"payment_id": string | null,"reason": string | null,"refund_request_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "bank_account_id": string,"bank_transaction_id": string,"cash_entry_id"?: string | null,"decided_at"?: string,"decided_by"?: string | null,"kind": string,"method": string,"organization_id": string,"payment_id"?: string | null,"reason"?: string | null,"refund_request_id"?: string | null
                  }
                  Update: {
                    "bank_account_id"?: string,"bank_transaction_id"?: string,"cash_entry_id"?: string | null,"decided_at"?: string,"decided_by"?: string | null,"kind"?: string,"method"?: string,"organization_id"?: string,"payment_id"?: string | null,"reason"?: string | null,"refund_request_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "bank_debit_link_bank_transaction_id_fkey"
      columns: ["bank_transaction_id"]
isOneToOne: true
      referencedRelation: "bank_transaction"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bank_debit_link_cash_entry_id_fkey"
      columns: ["cash_entry_id"]
isOneToOne: true
      referencedRelation: "ledger_entry"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bank_debit_link_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bank_debit_link_payment_fk"
      columns: ["payment_id","organization_id"]
isOneToOne: false
      referencedRelation: "payment"
      referencedColumns: ["id","organization_id"]
    },{
      foreignKeyName: "bank_debit_link_refund_request_id_fkey"
      columns: ["refund_request_id"]
isOneToOne: false
      referencedRelation: "refund_request"
      referencedColumns: ["id"]
    }
                  ]
                },"bank_debit_review": {
                  Row: {
                    "bank_transaction_id": string,"candidates": NonNullable<Json>,"checked_at": string,"detail": string | null,"organization_id": string,"reason": string
                  }
                  ComputedFields: never
                  Insert: {
                    "bank_transaction_id": string,"candidates"?: NonNullable<Json>,"checked_at"?: string,"detail"?: string | null,"organization_id": string,"reason": string
                  }
                  Update: {
                    "bank_transaction_id"?: string,"candidates"?: NonNullable<Json>,"checked_at"?: string,"detail"?: string | null,"organization_id"?: string,"reason"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "bank_debit_review_bank_transaction_id_fkey"
      columns: ["bank_transaction_id"]
isOneToOne: true
      referencedRelation: "bank_transaction"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bank_debit_review_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    }
                  ]
                },"bank_duplicate_resolution": {
                  Row: {
                    "bank_account_id": string,"bank_transaction_id": string,"decided_at": string,"decided_by": string,"decision": string,"organization_id": string,"reason": string,"released_kind": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "bank_account_id": string,"bank_transaction_id": string,"decided_at"?: string,"decided_by": string,"decision": string,"organization_id": string,"reason": string,"released_kind"?: string | null
                  }
                  Update: {
                    "bank_account_id"?: string,"bank_transaction_id"?: string,"decided_at"?: string,"decided_by"?: string,"decision"?: string,"organization_id"?: string,"reason"?: string,"released_kind"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "bank_duplicate_resolution_bank_transaction_id_fkey"
      columns: ["bank_transaction_id"]
isOneToOne: true
      referencedRelation: "bank_transaction"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bank_duplicate_resolution_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    }
                  ]
                },"bank_line_booking": {
                  Row: {
                    "amount_minor": number,"bank_account_id": string,"bank_transaction_id": string,"decided_at": string,"decided_by": string | null,"entry_id": string,"kind": string,"method": string,"organization_id": string,"reason": string | null,"seq": number,"transfer_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "amount_minor": number,"bank_account_id": string,"bank_transaction_id": string,"decided_at"?: string,"decided_by"?: string | null,"entry_id": string,"kind": string,"method": string,"organization_id": string,"reason"?: string | null,"seq": number,"transfer_id"?: string | null
                  }
                  Update: {
                    "amount_minor"?: number,"bank_account_id"?: string,"bank_transaction_id"?: string,"decided_at"?: string,"decided_by"?: string | null,"entry_id"?: string,"kind"?: string,"method"?: string,"organization_id"?: string,"reason"?: string | null,"seq"?: number,"transfer_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "bank_line_booking_bank_transaction_id_fkey"
      columns: ["bank_transaction_id"]
isOneToOne: false
      referencedRelation: "bank_transaction"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bank_line_booking_entry_id_fkey"
      columns: ["entry_id"]
isOneToOne: true
      referencedRelation: "ledger_entry"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bank_line_booking_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bank_line_booking_transfer_id_fkey"
      columns: ["transfer_id"]
isOneToOne: false
      referencedRelation: "bank_transfer"
      referencedColumns: ["id"]
    }
                  ]
                },"bank_own_credit_release": {
                  Row: {
                    "bank_account_id": string,"bank_transaction_id": string,"decided_at": string,"decided_by": string,"organization_id": string,"reason": string
                  }
                  ComputedFields: never
                  Insert: {
                    "bank_account_id": string,"bank_transaction_id": string,"decided_at"?: string,"decided_by": string,"organization_id": string,"reason": string
                  }
                  Update: {
                    "bank_account_id"?: string,"bank_transaction_id"?: string,"decided_at"?: string,"decided_by"?: string,"organization_id"?: string,"reason"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "bank_own_credit_release_bank_transaction_id_fkey"
      columns: ["bank_transaction_id"]
isOneToOne: true
      referencedRelation: "bank_transaction"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bank_own_credit_release_organization_id_fkey"
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
                    "acct_svcr_ref": string | null,"amount_minor": number,"bank_account_id": string,"bank_tx_code": string | null,"batch_entry_ref": string | null,"booking_date": string,"counterparty_iban": string | null,"counterparty_name": string | null,"created_at": string,"creditor_reference": string | null,"currency": string,"dedup_key": string,"direction": string,"end_to_end_id": string | null,"entry_ref": string | null,"id": string,"kind": string,"line_no": number,"mandate_ref": string | null,"organization_id": string,"original_end_to_end_id": string | null,"payment_info_id": string | null,"remittance_text": string | null,"return_reason": string | null,"reversal_indicator": boolean,"statement_id": string,"tx_id": string | null,"ultimate_counterparty_name": string | null,"value_date": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "acct_svcr_ref"?: string | null,"amount_minor": number,"bank_account_id": string,"bank_tx_code"?: string | null,"batch_entry_ref"?: string | null,"booking_date": string,"counterparty_iban"?: string | null,"counterparty_name"?: string | null,"created_at"?: string,"creditor_reference"?: string | null,"currency": string,"dedup_key": string,"direction": string,"end_to_end_id"?: string | null,"entry_ref"?: string | null,"id"?: string,"kind": string,"line_no": number,"mandate_ref"?: string | null,"organization_id": string,"original_end_to_end_id"?: string | null,"payment_info_id"?: string | null,"remittance_text"?: string | null,"return_reason"?: string | null,"reversal_indicator"?: boolean,"statement_id": string,"tx_id"?: string | null,"ultimate_counterparty_name"?: string | null,"value_date"?: string | null
                  }
                  Update: {
                    "acct_svcr_ref"?: string | null,"amount_minor"?: number,"bank_account_id"?: string,"bank_tx_code"?: string | null,"batch_entry_ref"?: string | null,"booking_date"?: string,"counterparty_iban"?: string | null,"counterparty_name"?: string | null,"created_at"?: string,"creditor_reference"?: string | null,"currency"?: string,"dedup_key"?: string,"direction"?: string,"end_to_end_id"?: string | null,"entry_ref"?: string | null,"id"?: string,"kind"?: string,"line_no"?: number,"mandate_ref"?: string | null,"organization_id"?: string,"original_end_to_end_id"?: string | null,"payment_info_id"?: string | null,"remittance_text"?: string | null,"return_reason"?: string | null,"reversal_indicator"?: boolean,"statement_id"?: string,"tx_id"?: string | null,"ultimate_counterparty_name"?: string | null,"value_date"?: string | null
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
                },"bank_transfer": {
                  Row: {
                    "amount_minor": number,"cancel_reason": string | null,"cancelled_at": string | null,"cancelled_by": string | null,"client_organization_id": string | null,"created_at": string,"creditor_bank_account_id": string | null,"currency": string,"debtor_bank_account_id": string,"end_to_end_id": string,"entry_id": string | null,"id": string,"kind": string,"ordered_by": string | null,"organization_id": string,"payee_bic": string | null,"payee_iban": string,"payee_name": string,"reason": string | null,"remittance_info": string | null,"requested_execution_date": string,"return_entry_id": string | null,"run_id": string | null,"status": string,"transfer_file_id": string | null,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "amount_minor": number,"cancel_reason"?: string | null,"cancelled_at"?: string | null,"cancelled_by"?: string | null,"client_organization_id"?: string | null,"created_at"?: string,"creditor_bank_account_id"?: string | null,"currency": string,"debtor_bank_account_id": string,"end_to_end_id": string,"entry_id"?: string | null,"id"?: string,"kind": string,"ordered_by"?: string | null,"organization_id": string,"payee_bic"?: string | null,"payee_iban": string,"payee_name": string,"reason"?: string | null,"remittance_info"?: string | null,"requested_execution_date": string,"return_entry_id"?: string | null,"run_id"?: string | null,"status"?: string,"transfer_file_id"?: string | null,"updated_at"?: string
                  }
                  Update: {
                    "amount_minor"?: number,"cancel_reason"?: string | null,"cancelled_at"?: string | null,"cancelled_by"?: string | null,"client_organization_id"?: string | null,"created_at"?: string,"creditor_bank_account_id"?: string | null,"currency"?: string,"debtor_bank_account_id"?: string,"end_to_end_id"?: string,"entry_id"?: string | null,"id"?: string,"kind"?: string,"ordered_by"?: string | null,"organization_id"?: string,"payee_bic"?: string | null,"payee_iban"?: string,"payee_name"?: string,"reason"?: string | null,"remittance_info"?: string | null,"requested_execution_date"?: string,"return_entry_id"?: string | null,"run_id"?: string | null,"status"?: string,"transfer_file_id"?: string | null,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "bank_transfer_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bank_transfer_creditor_fk"
      columns: ["creditor_bank_account_id","organization_id","currency"]
isOneToOne: false
      referencedRelation: "bank_account"
      referencedColumns: ["id","organization_id","currency"]
    },{
      foreignKeyName: "bank_transfer_debtor_fk"
      columns: ["debtor_bank_account_id","organization_id","currency"]
isOneToOne: false
      referencedRelation: "bank_account"
      referencedColumns: ["id","organization_id","currency"]
    },{
      foreignKeyName: "bank_transfer_entry_id_fkey"
      columns: ["entry_id"]
isOneToOne: true
      referencedRelation: "ledger_entry"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bank_transfer_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bank_transfer_return_entry_id_fkey"
      columns: ["return_entry_id"]
isOneToOne: true
      referencedRelation: "ledger_entry"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bank_transfer_run_id_fkey"
      columns: ["run_id"]
isOneToOne: false
      referencedRelation: "remittance_run"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "bank_transfer_transfer_file_id_fkey"
      columns: ["transfer_file_id"]
isOneToOne: false
      referencedRelation: "transfer_file"
      referencedColumns: ["id"]
    }
                  ]
                },"billing_identity": {
                  Row: {
                    "billing_address": Json | null,"created_at": string,"entrepreneur_individuel": boolean,"established_in": NonNullable<Json>,"in_liquidation": boolean,"invoice_acceptance_ref": string | null,"is_professional": boolean,"legal_form": string | null,"organization_id": string,"rcs_city": string | null,"registered_office": NonNullable<Json>,"share_capital_minor": number | null,"updated_at": string,"updated_by": string | null,"vat_number": string | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "billing_address"?: Json | null,"created_at"?: string,"entrepreneur_individuel"?: never,"established_in"?: never,"in_liquidation"?: boolean,"invoice_acceptance_ref"?: string | null,"is_professional": boolean,"legal_form"?: string | null,"organization_id": string,"rcs_city"?: string | null,"registered_office": NonNullable<Json>,"share_capital_minor"?: number | null,"updated_at"?: string,"updated_by"?: string | null,"vat_number"?: string | null,"version"?: number
                  }
                  Update: {
                    "billing_address"?: Json | null,"created_at"?: string,"entrepreneur_individuel"?: never,"established_in"?: never,"in_liquidation"?: boolean,"invoice_acceptance_ref"?: string | null,"is_professional"?: boolean,"legal_form"?: string | null,"organization_id"?: string,"rcs_city"?: string | null,"registered_office"?: NonNullable<Json>,"share_capital_minor"?: number | null,"updated_at"?: string,"updated_by"?: string | null,"vat_number"?: string | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "billing_identity_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: true
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "billing_identity_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
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
                },"business_calendar": {
                  Row: {
                    "closed": boolean,"day": string,"label": string | null,"scope": string,"sources": (string)[]
                  }
                  ComputedFields: never
                  Insert: {
                    "closed": boolean,"day": string,"label"?: string | null,"scope"?: string,"sources"?: (string)[]
                  }
                  Update: {
                    "closed"?: boolean,"day"?: string,"label"?: string | null,"scope"?: string,"sources"?: (string)[]
                  }
                  Relationships: [
                    
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
                },"client_notification": {
                  Row: {
                    "account_id": string | null,"client_organization_id": string,"created_at": string,"delivered_at": string | null,"id": string,"kind": string,"ledger_entry_id": string | null,"organization_id": string,"payment_id": string,"portfolio_id": string | null,"reason": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id"?: string | null,"client_organization_id": string,"created_at"?: string,"delivered_at"?: string | null,"id"?: string,"kind": string,"ledger_entry_id"?: string | null,"organization_id": string,"payment_id": string,"portfolio_id"?: string | null,"reason"?: string | null
                  }
                  Update: {
                    "account_id"?: string | null,"client_organization_id"?: string,"created_at"?: string,"delivered_at"?: string | null,"id"?: string,"kind"?: string,"ledger_entry_id"?: string | null,"organization_id"?: string,"payment_id"?: string,"portfolio_id"?: string | null,"reason"?: string | null
                  }
                  Relationships: [
                    
                  ]
                },"client_payout_account": {
                  Row: {
                    "bic": string | null,"client_organization_id": string,"closed_at": string | null,"closed_by": string | null,"closed_reason": string | null,"confirmed_at": string | null,"confirmed_by": string | null,"confirmed_via": string | null,"created_at": string,"currency": string,"evidence_document_id": string,"holder_name": string,"iban": string,"id": string,"kind": string,"organization_id": string,"proposed_at": string,"proposed_by": string,"status": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "bic"?: string | null,"client_organization_id": string,"closed_at"?: string | null,"closed_by"?: string | null,"closed_reason"?: string | null,"confirmed_at"?: string | null,"confirmed_by"?: string | null,"confirmed_via"?: string | null,"created_at"?: string,"currency": string,"evidence_document_id": string,"holder_name": string,"iban": string,"id"?: string,"kind"?: string,"organization_id": string,"proposed_at"?: string,"proposed_by": string,"status"?: string,"updated_at"?: string
                  }
                  Update: {
                    "bic"?: string | null,"client_organization_id"?: string,"closed_at"?: string | null,"closed_by"?: string | null,"closed_reason"?: string | null,"confirmed_at"?: string | null,"confirmed_by"?: string | null,"confirmed_via"?: string | null,"created_at"?: string,"currency"?: string,"evidence_document_id"?: string,"holder_name"?: string,"iban"?: string,"id"?: string,"kind"?: string,"organization_id"?: string,"proposed_at"?: string,"proposed_by"?: string,"status"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "client_payout_account_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "client_payout_account_closed_by_fkey"
      columns: ["closed_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "client_payout_account_confirmed_by_fkey"
      columns: ["confirmed_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "client_payout_account_currency_fkey"
      columns: ["currency"]
isOneToOne: false
      referencedRelation: "currency"
      referencedColumns: ["code"]
    },{
      foreignKeyName: "client_payout_account_evidence_document_id_fkey"
      columns: ["evidence_document_id"]
isOneToOne: false
      referencedRelation: "document"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "client_payout_account_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "client_payout_account_proposed_by_fkey"
      columns: ["proposed_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    }
                  ]
                },"client_status_event": {
                  Row: {
                    "client_organization_id": string,"effective_date": string,"evidence_document_id": string,"id": string,"kind": string,"note": string | null,"organization_id": string,"payout_account_id": string | null,"recorded_at": string,"recorded_by": string
                  }
                  ComputedFields: never
                  Insert: {
                    "client_organization_id": string,"effective_date": string,"evidence_document_id": string,"id"?: string,"kind": string,"note"?: string | null,"organization_id": string,"payout_account_id"?: string | null,"recorded_at"?: string,"recorded_by": string
                  }
                  Update: {
                    "client_organization_id"?: string,"effective_date"?: string,"evidence_document_id"?: string,"id"?: string,"kind"?: string,"note"?: string | null,"organization_id"?: string,"payout_account_id"?: string | null,"recorded_at"?: string,"recorded_by"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "client_status_event_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "client_status_event_evidence_document_id_fkey"
      columns: ["evidence_document_id"]
isOneToOne: false
      referencedRelation: "document"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "client_status_event_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "client_status_event_payout_account_id_fkey"
      columns: ["payout_account_id"]
isOneToOne: false
      referencedRelation: "client_payout_account"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "client_status_event_recorded_by_fkey"
      columns: ["recorded_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    }
                  ]
                },"commission_credit_alloc": {
                  Row: {
                    "account_id": string,"credit_note_id": string,"entry_id": string | null,"ht_minor": number,"line_no": number,"original_invoice_id": string,"tier_key": string
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id": string,"credit_note_id": string,"entry_id"?: string | null,"ht_minor": number,"line_no": number,"original_invoice_id": string,"tier_key": string
                  }
                  Update: {
                    "account_id"?: string,"credit_note_id"?: string,"entry_id"?: string | null,"ht_minor"?: number,"line_no"?: number,"original_invoice_id"?: string,"tier_key"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "commission_credit_alloc_account_id_fkey"
      columns: ["account_id"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_credit_alloc_entry_id_fkey"
      columns: ["entry_id"]
isOneToOne: false
      referencedRelation: "ledger_entry"
      referencedColumns: ["id"]
    }
                  ]
                },"commission_credit_correction": {
                  Row: {
                    "applied_minor": number,"credit_note_id": string,"excess_minor": number,"ht_minor": number,"original_invoice_id": string,"vat_collected_minor": number,"vat_minor": number,"vat_pending_minor": number,"vat_rate": number
                  }
                  ComputedFields: never
                  Insert: {
                    "applied_minor": number,"credit_note_id": string,"excess_minor": number,"ht_minor": number,"original_invoice_id": string,"vat_collected_minor": number,"vat_minor": number,"vat_pending_minor": number,"vat_rate": number
                  }
                  Update: {
                    "applied_minor"?: number,"credit_note_id"?: string,"excess_minor"?: number,"ht_minor"?: number,"original_invoice_id"?: string,"vat_collected_minor"?: number,"vat_minor"?: number,"vat_pending_minor"?: number,"vat_rate"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "commission_credit_correction_credit_note_id_fkey"
      columns: ["credit_note_id"]
isOneToOne: false
      referencedRelation: "commission_invoice"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_credit_correction_original_invoice_id_fkey"
      columns: ["original_invoice_id"]
isOneToOne: false
      referencedRelation: "commission_invoice"
      referencedColumns: ["id"]
    }
                  ]
                },"commission_invoice": {
                  Row: {
                    "client_organization_id": string,"created_at": string,"currency": string,"due_date": string | null,"ht_minor": number,"id": string,"issue_date": string,"kind": string,"ledger_entry_id": string,"mandate_id": string,"number": string,"organization_id": string,"payload": NonNullable<Json>,"payload_sha256": string,"reason": string,"run_id": string | null,"seq": number,"series": string,"service_from": string | null,"service_to": string | null,"settlement": string,"ttc_minor": number,"vat_book": string | null,"vat_minor": number,"vat_rate": number | null,"year": number
                  }
                  ComputedFields: never
                  Insert: {
                    "client_organization_id": string,"created_at"?: string,"currency": string,"due_date"?: string | null,"ht_minor": number,"id": string,"issue_date": string,"kind": string,"ledger_entry_id": string,"mandate_id": string,"number": string,"organization_id": string,"payload": NonNullable<Json>,"payload_sha256": string,"reason": string,"run_id"?: string | null,"seq": number,"series": string,"service_from"?: string | null,"service_to"?: string | null,"settlement": string,"ttc_minor": number,"vat_book"?: string | null,"vat_minor": number,"vat_rate"?: number | null,"year": number
                  }
                  Update: {
                    "client_organization_id"?: string,"created_at"?: string,"currency"?: string,"due_date"?: string | null,"ht_minor"?: number,"id"?: string,"issue_date"?: string,"kind"?: string,"ledger_entry_id"?: string,"mandate_id"?: string,"number"?: string,"organization_id"?: string,"payload"?: NonNullable<Json>,"payload_sha256"?: string,"reason"?: string,"run_id"?: string | null,"seq"?: number,"series"?: string,"service_from"?: string | null,"service_to"?: string | null,"settlement"?: string,"ttc_minor"?: number,"vat_book"?: string | null,"vat_minor"?: number,"vat_rate"?: number | null,"year"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "commission_invoice_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_invoice_ledger_entry_id_fkey"
      columns: ["ledger_entry_id"]
isOneToOne: true
      referencedRelation: "ledger_entry"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_invoice_mandate_id_fkey"
      columns: ["mandate_id"]
isOneToOne: false
      referencedRelation: "mandate"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_invoice_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_invoice_run_id_fkey"
      columns: ["run_id"]
isOneToOne: false
      referencedRelation: "remittance_run"
      referencedColumns: ["id"]
    }
                  ]
                },"commission_invoice_charge": {
                  Row: {
                    "account_id": string,"charged_minor": number,"invoice_id": string,"tier_key": string
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id": string,"charged_minor": number,"invoice_id": string,"tier_key": string
                  }
                  Update: {
                    "account_id"?: string,"charged_minor"?: number,"invoice_id"?: string,"tier_key"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "commission_invoice_charge_account_id_fkey"
      columns: ["account_id"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_invoice_charge_invoice_id_fkey"
      columns: ["invoice_id"]
isOneToOne: false
      referencedRelation: "commission_invoice"
      referencedColumns: ["id"]
    }
                  ]
                },"commission_invoice_document": {
                  Row: {
                    "client_organization_id": string,"created_at": string,"document_id": string,"electronic": boolean,"invoice_id": string,"organization_id": string,"pdf_sha256": string,"renderer_version": string,"template_version": string
                  }
                  ComputedFields: never
                  Insert: {
                    "client_organization_id": string,"created_at"?: string,"document_id": string,"electronic": boolean,"invoice_id": string,"organization_id": string,"pdf_sha256": string,"renderer_version": string,"template_version": string
                  }
                  Update: {
                    "client_organization_id"?: string,"created_at"?: string,"document_id"?: string,"electronic"?: boolean,"invoice_id"?: string,"organization_id"?: string,"pdf_sha256"?: string,"renderer_version"?: string,"template_version"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "commission_invoice_document_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_invoice_document_document_id_fkey"
      columns: ["document_id"]
isOneToOne: true
      referencedRelation: "document"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_invoice_document_invoice_id_fkey"
      columns: ["invoice_id"]
isOneToOne: true
      referencedRelation: "commission_invoice"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_invoice_document_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    }
                  ]
                },"commission_invoice_line": {
                  Row: {
                    "claim_type_code": string | null,"designation_fr": string,"families": (string)[],"ht_minor": number,"invoice_id": string,"kind": string,"line_no": number,"original_invoice_id": string | null,"quantity": number,"rule_id": string | null,"tiers": NonNullable<Json>,"vat_rate": number
                  }
                  ComputedFields: never
                  Insert: {
                    "claim_type_code"?: string | null,"designation_fr": string,"families"?: (string)[],"ht_minor": number,"invoice_id": string,"kind": string,"line_no": number,"original_invoice_id"?: string | null,"quantity"?: number,"rule_id"?: string | null,"tiers"?: NonNullable<Json>,"vat_rate": number
                  }
                  Update: {
                    "claim_type_code"?: string | null,"designation_fr"?: string,"families"?: (string)[],"ht_minor"?: number,"invoice_id"?: string,"kind"?: string,"line_no"?: number,"original_invoice_id"?: string | null,"quantity"?: number,"rule_id"?: string | null,"tiers"?: NonNullable<Json>,"vat_rate"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "commission_invoice_line_invoice_id_fkey"
      columns: ["invoice_id"]
isOneToOne: false
      referencedRelation: "commission_invoice"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_invoice_line_original_invoice_id_fkey"
      columns: ["original_invoice_id"]
isOneToOne: false
      referencedRelation: "commission_invoice"
      referencedColumns: ["id"]
    }
                  ]
                },"commission_settlement": {
                  Row: {
                    "amount_minor": number,"client_organization_id": string,"created_at": string,"credit_note_id": string | null,"document_id": string,"document_kind": string,"entry_id": string | null,"id": string,"kind": string,"organization_id": string,"run_id": string | null,"settled_on": string,"vat_moved_minor": number
                  }
                  ComputedFields: never
                  Insert: {
                    "amount_minor": number,"client_organization_id": string,"created_at"?: string,"credit_note_id"?: string | null,"document_id": string,"document_kind": string,"entry_id"?: string | null,"id"?: string,"kind": string,"organization_id": string,"run_id"?: string | null,"settled_on": string,"vat_moved_minor"?: number
                  }
                  Update: {
                    "amount_minor"?: number,"client_organization_id"?: string,"created_at"?: string,"credit_note_id"?: string | null,"document_id"?: string,"document_kind"?: string,"entry_id"?: string | null,"id"?: string,"kind"?: string,"organization_id"?: string,"run_id"?: string | null,"settled_on"?: string,"vat_moved_minor"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "commission_settlement_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_settlement_credit_note_id_fkey"
      columns: ["credit_note_id"]
isOneToOne: false
      referencedRelation: "commission_invoice"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_settlement_entry_id_fkey"
      columns: ["entry_id"]
isOneToOne: false
      referencedRelation: "ledger_entry"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_settlement_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_settlement_run_id_fkey"
      columns: ["run_id"]
isOneToOne: false
      referencedRelation: "remittance_run"
      referencedColumns: ["id"]
    }
                  ]
                },"commission_waiver": {
                  Row: {
                    "account_id": string,"amount_minor": number,"cause": string,"client_organization_id": string,"created_at": string,"credit_note_id": string | null,"entry_id": string | null,"id": number,"invoice_id": string,"organization_id": string,"run_id": string | null,"tier_key": string
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id": string,"amount_minor": number,"cause": string,"client_organization_id": string,"created_at"?: string,"credit_note_id"?: string | null,"entry_id"?: string | null,"id"?: never,"invoice_id": string,"organization_id": string,"run_id"?: string | null,"tier_key": string
                  }
                  Update: {
                    "account_id"?: string,"amount_minor"?: number,"cause"?: string,"client_organization_id"?: string,"created_at"?: string,"credit_note_id"?: string | null,"entry_id"?: string | null,"id"?: never,"invoice_id"?: string,"organization_id"?: string,"run_id"?: string | null,"tier_key"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "commission_waiver_account_id_fkey"
      columns: ["account_id"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_waiver_credit_note_id_fkey"
      columns: ["credit_note_id"]
isOneToOne: false
      referencedRelation: "commission_invoice"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_waiver_entry_id_fkey"
      columns: ["entry_id"]
isOneToOne: false
      referencedRelation: "ledger_entry"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_waiver_invoice_id_fkey"
      columns: ["invoice_id"]
isOneToOne: false
      referencedRelation: "commission_invoice"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "commission_waiver_run_id_fkey"
      columns: ["run_id"]
isOneToOne: false
      referencedRelation: "remittance_run"
      referencedColumns: ["id"]
    }
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
                },"direct_payment": {
                  Row: {
                    "account_id": string,"amount_minor": number,"client_organization_id": string,"currency": string,"decided_at": string | null,"entry_id": string | null,"evidence_document_id": string,"id": string,"item_ids": (string)[],"organization_id": string,"paid_on": string,"portfolio_id": string,"reason": string,"refusal_code": string | null,"requested_at": string,"requested_by": string,"status": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id": string,"amount_minor": number,"client_organization_id": string,"currency": string,"decided_at"?: string | null,"entry_id"?: string | null,"evidence_document_id": string,"id"?: string,"item_ids"?: (string)[],"organization_id": string,"paid_on": string,"portfolio_id": string,"reason": string,"refusal_code"?: string | null,"requested_at"?: string,"requested_by": string,"status"?: string,"updated_at"?: string
                  }
                  Update: {
                    "account_id"?: string,"amount_minor"?: number,"client_organization_id"?: string,"currency"?: string,"decided_at"?: string | null,"entry_id"?: string | null,"evidence_document_id"?: string,"id"?: string,"item_ids"?: (string)[],"organization_id"?: string,"paid_on"?: string,"portfolio_id"?: string,"reason"?: string,"refusal_code"?: string | null,"requested_at"?: string,"requested_by"?: string,"status"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "direct_payment_account_fk"
      columns: ["account_id","organization_id","client_organization_id","portfolio_id"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id","organization_id","client_organization_id","portfolio_id"]
    },{
      foreignKeyName: "direct_payment_currency_fkey"
      columns: ["currency"]
isOneToOne: false
      referencedRelation: "currency"
      referencedColumns: ["code"]
    },{
      foreignKeyName: "direct_payment_entry_id_fkey"
      columns: ["entry_id"]
isOneToOne: true
      referencedRelation: "ledger_entry"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "direct_payment_evidence_document_id_fkey"
      columns: ["evidence_document_id"]
isOneToOne: false
      referencedRelation: "document"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "direct_payment_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    }
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
                    "client_organization_id": string,"created_at": string,"id": string,"insurance_clause_ref": string | null,"mandate_type": string,"organization_id": string,"reference": string,"signed_document_id": string | null,"signed_on": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "client_organization_id": string,"created_at"?: string,"id"?: string,"insurance_clause_ref"?: string | null,"mandate_type": string,"organization_id": string,"reference": string,"signed_document_id"?: string | null,"signed_on": string,"updated_at"?: string
                  }
                  Update: {
                    "client_organization_id"?: string,"created_at"?: string,"id"?: string,"insurance_clause_ref"?: string | null,"mandate_type"?: string,"organization_id"?: string,"reference"?: string,"signed_document_id"?: string | null,"signed_on"?: string,"updated_at"?: string
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
                    "commission_clause_ref": string | null,"commission_rate": number | null,"commission_schedule": Json | null,"created_at": string,"created_by": string | null,"document_id": string | null,"id": string,"mandate_id": string,"plan_envelope": NonNullable<Json>,"remittance_clause_ref": string | null,"remittance_max_days": number,"remittance_terms": Json | null,"schedule_sha256": string | null,"settlement_authority": NonNullable<Json>,"terms": NonNullable<Json>,"valid_from": string,"valid_to": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "commission_clause_ref"?: string | null,"commission_rate"?: number | null,"commission_schedule"?: Json | null,"created_at"?: string,"created_by"?: string | null,"document_id"?: string | null,"id"?: string,"mandate_id": string,"plan_envelope"?: NonNullable<Json>,"remittance_clause_ref"?: string | null,"remittance_max_days"?: number,"remittance_terms"?: Json | null,"schedule_sha256"?: string | null,"settlement_authority"?: NonNullable<Json>,"terms"?: NonNullable<Json>,"valid_from": string,"valid_to"?: string | null
                  }
                  Update: {
                    "commission_clause_ref"?: string | null,"commission_rate"?: number | null,"commission_schedule"?: Json | null,"created_at"?: string,"created_by"?: string | null,"document_id"?: string | null,"id"?: string,"mandate_id"?: string,"plan_envelope"?: NonNullable<Json>,"remittance_clause_ref"?: string | null,"remittance_max_days"?: number,"remittance_terms"?: Json | null,"schedule_sha256"?: string | null,"settlement_authority"?: NonNullable<Json>,"terms"?: NonNullable<Json>,"valid_from"?: string,"valid_to"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "mandate_terms_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "mandate_terms_document_id_fkey"
      columns: ["document_id"]
isOneToOne: false
      referencedRelation: "document"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "mandate_terms_mandate_id_fkey"
      columns: ["mandate_id"]
isOneToOne: false
      referencedRelation: "mandate"
      referencedColumns: ["id"]
    }
                  ]
                },"manual_credit_note": {
                  Row: {
                    "account_id": string | null,"amount_minor": number,"client_organization_id": string,"created_at": string,"credit_note_id": string,"invoice_id": string,"issued_by": string | null,"organization_id": string,"reason": string,"reason_code": string
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id"?: string | null,"amount_minor": number,"client_organization_id": string,"created_at"?: string,"credit_note_id": string,"invoice_id": string,"issued_by"?: string | null,"organization_id": string,"reason": string,"reason_code": string
                  }
                  Update: {
                    "account_id"?: string | null,"amount_minor"?: number,"client_organization_id"?: string,"created_at"?: string,"credit_note_id"?: string,"invoice_id"?: string,"issued_by"?: string | null,"organization_id"?: string,"reason"?: string,"reason_code"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "manual_credit_note_account_id_fkey"
      columns: ["account_id"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "manual_credit_note_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "manual_credit_note_credit_note_id_fkey"
      columns: ["credit_note_id"]
isOneToOne: true
      referencedRelation: "commission_invoice"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "manual_credit_note_invoice_id_fkey"
      columns: ["invoice_id"]
isOneToOne: false
      referencedRelation: "commission_invoice"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "manual_credit_note_issued_by_fkey"
      columns: ["issued_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "manual_credit_note_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
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
                },"payee_name_check": {
                  Row: {
                    "bank_name": string | null,"clear_reason": string | null,"cleared_at": string | null,"cleared_by": string | null,"client_organization_id": string,"id": string,"note": string,"organization_id": string,"payout_account_id": string,"recorded_at": string,"recorded_by": string,"result": string,"transfer_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "bank_name"?: string | null,"clear_reason"?: string | null,"cleared_at"?: string | null,"cleared_by"?: string | null,"client_organization_id": string,"id"?: string,"note": string,"organization_id": string,"payout_account_id": string,"recorded_at"?: string,"recorded_by": string,"result": string,"transfer_id"?: string | null
                  }
                  Update: {
                    "bank_name"?: string | null,"clear_reason"?: string | null,"cleared_at"?: string | null,"cleared_by"?: string | null,"client_organization_id"?: string,"id"?: string,"note"?: string,"organization_id"?: string,"payout_account_id"?: string,"recorded_at"?: string,"recorded_by"?: string,"result"?: string,"transfer_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "payee_name_check_cleared_by_fkey"
      columns: ["cleared_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payee_name_check_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payee_name_check_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payee_name_check_payout_account_id_fkey"
      columns: ["payout_account_id"]
isOneToOne: false
      referencedRelation: "client_payout_account"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payee_name_check_recorded_by_fkey"
      columns: ["recorded_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payee_name_check_transfer_id_fkey"
      columns: ["transfer_id"]
isOneToOne: false
      referencedRelation: "bank_transfer"
      referencedColumns: ["id"]
    }
                  ]
                },"payment": {
                  Row: {
                    "account_id": string | null,"allocation_instruction": Json | null,"amount_minor": number,"bank_account_id": string | null,"bank_transaction_id": string | null,"booking_date": string,"candidate_account_id": string | null,"channel": string,"client_organization_id": string | null,"created_at": string,"creditor_reference": string | null,"currency": string,"designation": Json | null,"end_to_end_id": string | null,"id": string,"match_method": string | null,"matched_at": string | null,"method": string,"organization_id": string,"payer_iban": string | null,"payer_name": string | null,"portfolio_id": string | null,"remittance_text": string | null,"review_reason": string | null,"status": string,"updated_at": string,"value_date": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id"?: string | null,"allocation_instruction"?: Json | null,"amount_minor": number,"bank_account_id"?: string | null,"bank_transaction_id"?: string | null,"booking_date": string,"candidate_account_id"?: string | null,"channel": string,"client_organization_id"?: string | null,"created_at"?: string,"creditor_reference"?: string | null,"currency": string,"designation"?: Json | null,"end_to_end_id"?: string | null,"id"?: string,"match_method"?: string | null,"matched_at"?: string | null,"method": string,"organization_id": string,"payer_iban"?: string | null,"payer_name"?: string | null,"portfolio_id"?: string | null,"remittance_text"?: string | null,"review_reason"?: string | null,"status"?: string,"updated_at"?: string,"value_date"?: string | null
                  }
                  Update: {
                    "account_id"?: string | null,"allocation_instruction"?: Json | null,"amount_minor"?: number,"bank_account_id"?: string | null,"bank_transaction_id"?: string | null,"booking_date"?: string,"candidate_account_id"?: string | null,"channel"?: string,"client_organization_id"?: string | null,"created_at"?: string,"creditor_reference"?: string | null,"currency"?: string,"designation"?: Json | null,"end_to_end_id"?: string | null,"id"?: string,"match_method"?: string | null,"matched_at"?: string | null,"method"?: string,"organization_id"?: string,"payer_iban"?: string | null,"payer_name"?: string | null,"portfolio_id"?: string | null,"remittance_text"?: string | null,"review_reason"?: string | null,"status"?: string,"updated_at"?: string,"value_date"?: string | null
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
                },"payment_check_result": {
                  Row: {
                    "amount_minor": number | null,"code": string,"count": number | null,"currency": string | null,"details": NonNullable<Json>,"id": string,"oldest_days": number | null,"organization_id": string,"run_id": string,"severity": string,"subject_id": string | null,"subject_type": string
                  }
                  ComputedFields: never
                  Insert: {
                    "amount_minor"?: number | null,"code": string,"count"?: number | null,"currency"?: string | null,"details"?: NonNullable<Json>,"id"?: string,"oldest_days"?: number | null,"organization_id": string,"run_id": string,"severity": string,"subject_id"?: string | null,"subject_type": string
                  }
                  Update: {
                    "amount_minor"?: number | null,"code"?: string,"count"?: number | null,"currency"?: string | null,"details"?: NonNullable<Json>,"id"?: string,"oldest_days"?: number | null,"organization_id"?: string,"run_id"?: string,"severity"?: string,"subject_id"?: string | null,"subject_type"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "payment_check_result_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "payment_check_result_run_id_fkey"
      columns: ["run_id"]
isOneToOne: false
      referencedRelation: "payment_check_run"
      referencedColumns: ["id"]
    }
                  ]
                },"payment_check_run": {
                  Row: {
                    "alerts": number | null,"finished_at": string | null,"id": string,"organization_id": string,"started_at": string,"summary": Json | null,"violations": number | null
                  }
                  ComputedFields: never
                  Insert: {
                    "alerts"?: number | null,"finished_at"?: string | null,"id"?: string,"organization_id": string,"started_at"?: string,"summary"?: Json | null,"violations"?: number | null
                  }
                  Update: {
                    "alerts"?: number | null,"finished_at"?: string | null,"id"?: string,"organization_id"?: string,"started_at"?: string,"summary"?: Json | null,"violations"?: number | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "payment_check_run_organization_id_fkey"
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
                },"receipt": {
                  Row: {
                    "account_id": string,"client_organization_id": string,"document_id": string,"id": string,"issued_at": string,"kind": string,"known_at": string,"number": string,"organization_id": string,"payload": NonNullable<Json>,"payload_sha256": string,"payment_id": string,"pdf_sha256": string,"portfolio_id": string,"recipient_party_id": string | null,"renderer_version": string,"template_version": string,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id": string,"client_organization_id": string,"document_id": string,"id"?: string,"issued_at"?: string,"kind": string,"known_at": string,"number": string,"organization_id": string,"payload": NonNullable<Json>,"payload_sha256": string,"payment_id": string,"pdf_sha256": string,"portfolio_id": string,"recipient_party_id"?: string | null,"renderer_version": string,"template_version": string,"version": number
                  }
                  Update: {
                    "account_id"?: string,"client_organization_id"?: string,"document_id"?: string,"id"?: string,"issued_at"?: string,"kind"?: string,"known_at"?: string,"number"?: string,"organization_id"?: string,"payload"?: NonNullable<Json>,"payload_sha256"?: string,"payment_id"?: string,"pdf_sha256"?: string,"portfolio_id"?: string,"recipient_party_id"?: string | null,"renderer_version"?: string,"template_version"?: string,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "receipt_account_fk"
      columns: ["account_id","organization_id","client_organization_id","portfolio_id"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id","organization_id","client_organization_id","portfolio_id"]
    },{
      foreignKeyName: "receipt_document_id_fkey"
      columns: ["document_id"]
isOneToOne: true
      referencedRelation: "document"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "receipt_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "receipt_payment_id_fkey"
      columns: ["payment_id"]
isOneToOne: false
      referencedRelation: "payment"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "receipt_recipient_party_id_fkey"
      columns: ["recipient_party_id"]
isOneToOne: false
      referencedRelation: "party"
      referencedColumns: ["id"]
    }
                  ]
                },"refund_request": {
                  Row: {
                    "amount_minor": number,"bank_account_id": string,"bank_transaction_id": string | null,"bounce_entry_id": string | null,"bounce_transaction_id": string | null,"cancel_reason": string | null,"cancelled_at": string | null,"cancelled_by": string | null,"cash_out_entry_id": string | null,"currency": string,"end_to_end_id": string,"executed_on": string | null,"execution_mode": string,"id": string,"organization_id": string,"payee_iban": string,"payee_is_payer": boolean,"payee_name": string,"payment_id": string,"prior_review_reason": string | null,"prior_status": string,"reason": string,"reason_code": string,"requested_at": string,"requested_by": string,"status": string,"transfer_id": string | null,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "amount_minor": number,"bank_account_id": string,"bank_transaction_id"?: string | null,"bounce_entry_id"?: string | null,"bounce_transaction_id"?: string | null,"cancel_reason"?: string | null,"cancelled_at"?: string | null,"cancelled_by"?: string | null,"cash_out_entry_id"?: string | null,"currency": string,"end_to_end_id": string,"executed_on"?: string | null,"execution_mode"?: string,"id"?: string,"organization_id": string,"payee_iban": string,"payee_is_payer": boolean,"payee_name": string,"payment_id": string,"prior_review_reason"?: string | null,"prior_status": string,"reason": string,"reason_code": string,"requested_at"?: string,"requested_by": string,"status"?: string,"transfer_id"?: string | null,"updated_at"?: string
                  }
                  Update: {
                    "amount_minor"?: number,"bank_account_id"?: string,"bank_transaction_id"?: string | null,"bounce_entry_id"?: string | null,"bounce_transaction_id"?: string | null,"cancel_reason"?: string | null,"cancelled_at"?: string | null,"cancelled_by"?: string | null,"cash_out_entry_id"?: string | null,"currency"?: string,"end_to_end_id"?: string,"executed_on"?: string | null,"execution_mode"?: string,"id"?: string,"organization_id"?: string,"payee_iban"?: string,"payee_is_payer"?: boolean,"payee_name"?: string,"payment_id"?: string,"prior_review_reason"?: string | null,"prior_status"?: string,"reason"?: string,"reason_code"?: string,"requested_at"?: string,"requested_by"?: string,"status"?: string,"transfer_id"?: string | null,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "refund_request_bank_fk"
      columns: ["bank_account_id","organization_id","currency"]
isOneToOne: false
      referencedRelation: "bank_account"
      referencedColumns: ["id","organization_id","currency"]
    },{
      foreignKeyName: "refund_request_bank_transaction_id_fkey"
      columns: ["bank_transaction_id"]
isOneToOne: true
      referencedRelation: "bank_transaction"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "refund_request_bounce_entry_id_fkey"
      columns: ["bounce_entry_id"]
isOneToOne: true
      referencedRelation: "ledger_entry"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "refund_request_bounce_transaction_id_fkey"
      columns: ["bounce_transaction_id"]
isOneToOne: true
      referencedRelation: "bank_transaction"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "refund_request_cash_out_entry_id_fkey"
      columns: ["cash_out_entry_id"]
isOneToOne: true
      referencedRelation: "ledger_entry"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "refund_request_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "refund_request_payment_fk"
      columns: ["payment_id","organization_id"]
isOneToOne: false
      referencedRelation: "payment"
      referencedColumns: ["id","organization_id"]
    },{
      foreignKeyName: "refund_request_transfer_id_fkey"
      columns: ["transfer_id"]
isOneToOne: true
      referencedRelation: "bank_transfer"
      referencedColumns: ["id"]
    }
                  ]
                },"remittance_deadline_breach": {
                  Row: {
                    "blocked_reason": string | null,"client_organization_id": string,"deadline": string | null,"detected_at": string,"id": string,"late_reason": string | null,"latest_execution_date": string,"ledger_entry_id": string,"organization_id": string,"payment_id": string | null,"requested_execution_date": string | null,"run_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "blocked_reason"?: string | null,"client_organization_id": string,"deadline"?: string | null,"detected_at"?: string,"id"?: string,"late_reason"?: string | null,"latest_execution_date": string,"ledger_entry_id": string,"organization_id": string,"payment_id"?: string | null,"requested_execution_date"?: string | null,"run_id"?: string | null
                  }
                  Update: {
                    "blocked_reason"?: string | null,"client_organization_id"?: string,"deadline"?: string | null,"detected_at"?: string,"id"?: string,"late_reason"?: string | null,"latest_execution_date"?: string,"ledger_entry_id"?: string,"organization_id"?: string,"payment_id"?: string | null,"requested_execution_date"?: string | null,"run_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "remittance_deadline_breach_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_deadline_breach_ledger_entry_id_fkey"
      columns: ["ledger_entry_id"]
isOneToOne: true
      referencedRelation: "ledger_entry"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_deadline_breach_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_deadline_breach_payment_id_fkey"
      columns: ["payment_id"]
isOneToOne: false
      referencedRelation: "payment"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_deadline_breach_run_id_fkey"
      columns: ["run_id"]
isOneToOne: false
      referencedRelation: "remittance_run"
      referencedColumns: ["id"]
    }
                  ]
                },"remittance_key_state": {
                  Row: {
                    "account_id": string,"basis": NonNullable<Json>,"cause": string,"client_organization_id": string,"commission_minor": number,"created_at": string,"credit_note_id": string | null,"kept_basis_minor": number,"kept_minor": number,"organization_id": string,"run_id": string | null,"seq": number,"tier_key": string,"waived_minor": number
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id": string,"basis"?: NonNullable<Json>,"cause": string,"client_organization_id": string,"commission_minor"?: number,"created_at"?: string,"credit_note_id"?: string | null,"kept_basis_minor"?: number,"kept_minor"?: number,"organization_id": string,"run_id"?: string | null,"seq"?: never,"tier_key": string,"waived_minor"?: number
                  }
                  Update: {
                    "account_id"?: string,"basis"?: NonNullable<Json>,"cause"?: string,"client_organization_id"?: string,"commission_minor"?: number,"created_at"?: string,"credit_note_id"?: string | null,"kept_basis_minor"?: number,"kept_minor"?: number,"organization_id"?: string,"run_id"?: string | null,"seq"?: never,"tier_key"?: string,"waived_minor"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "remittance_key_state_account_id_fkey"
      columns: ["account_id"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_key_state_credit_note_id_fkey"
      columns: ["credit_note_id"]
isOneToOne: false
      referencedRelation: "commission_invoice"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_key_state_run_id_fkey"
      columns: ["run_id"]
isOneToOne: false
      referencedRelation: "remittance_run"
      referencedColumns: ["id"]
    }
                  ]
                },"remittance_late_approval": {
                  Row: {
                    "approved_by": string | null,"client_organization_id": string,"created_at": string,"late_reason": string,"latest_execution_date": string,"ledger_entry_id": string,"organization_id": string,"requested_execution_date": string,"run_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "approved_by"?: string | null,"client_organization_id": string,"created_at"?: string,"late_reason": string,"latest_execution_date": string,"ledger_entry_id": string,"organization_id": string,"requested_execution_date": string,"run_id": string
                  }
                  Update: {
                    "approved_by"?: string | null,"client_organization_id"?: string,"created_at"?: string,"late_reason"?: string,"latest_execution_date"?: string,"ledger_entry_id"?: string,"organization_id"?: string,"requested_execution_date"?: string,"run_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "remittance_late_approval_approved_by_fkey"
      columns: ["approved_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_late_approval_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_late_approval_ledger_entry_id_fkey"
      columns: ["ledger_entry_id"]
isOneToOne: false
      referencedRelation: "ledger_entry"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_late_approval_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_late_approval_run_id_fkey"
      columns: ["run_id"]
isOneToOne: false
      referencedRelation: "remittance_run"
      referencedColumns: ["id"]
    }
                  ]
                },"remittance_line": {
                  Row: {
                    "account_id": string | null,"amount_minor": number,"basis": NonNullable<Json>,"client_organization_id": string,"commission_minor": number,"commission_reason": string | null,"commission_state": string,"currency": string,"deadline": string | null,"effective_date": string,"encaissement_date": string | null,"invoice_id": string | null,"kind": string,"latest_execution_date": string | null,"ledger_entry_id": string,"line_no": number,"mandate_id": string | null,"mandate_terms_id": string | null,"organization_id": string,"original_entry_id": string | null,"parts": NonNullable<Json>,"payment_id": string | null,"portfolio_id": string | null,"posted_at": string,"released": boolean,"released_at": string | null,"run_id": string,"unmeetable": boolean
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id"?: string | null,"amount_minor": number,"basis"?: NonNullable<Json>,"client_organization_id": string,"commission_minor"?: number,"commission_reason"?: string | null,"commission_state": string,"currency": string,"deadline"?: string | null,"effective_date": string,"encaissement_date"?: string | null,"invoice_id"?: string | null,"kind": string,"latest_execution_date"?: string | null,"ledger_entry_id": string,"line_no": number,"mandate_id"?: string | null,"mandate_terms_id"?: string | null,"organization_id": string,"original_entry_id"?: string | null,"parts"?: NonNullable<Json>,"payment_id"?: string | null,"portfolio_id"?: string | null,"posted_at": string,"released"?: boolean,"released_at"?: string | null,"run_id": string,"unmeetable"?: boolean
                  }
                  Update: {
                    "account_id"?: string | null,"amount_minor"?: number,"basis"?: NonNullable<Json>,"client_organization_id"?: string,"commission_minor"?: number,"commission_reason"?: string | null,"commission_state"?: string,"currency"?: string,"deadline"?: string | null,"effective_date"?: string,"encaissement_date"?: string | null,"invoice_id"?: string | null,"kind"?: string,"latest_execution_date"?: string | null,"ledger_entry_id"?: string,"line_no"?: number,"mandate_id"?: string | null,"mandate_terms_id"?: string | null,"organization_id"?: string,"original_entry_id"?: string | null,"parts"?: NonNullable<Json>,"payment_id"?: string | null,"portfolio_id"?: string | null,"posted_at"?: string,"released"?: boolean,"released_at"?: string | null,"run_id"?: string,"unmeetable"?: boolean
                  }
                  Relationships: [
                    {
      foreignKeyName: "remittance_line_account_id_fkey"
      columns: ["account_id"]
isOneToOne: false
      referencedRelation: "account"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_line_invoice_fk"
      columns: ["invoice_id"]
isOneToOne: false
      referencedRelation: "commission_invoice"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_line_ledger_entry_id_fkey"
      columns: ["ledger_entry_id"]
isOneToOne: false
      referencedRelation: "ledger_entry"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_line_mandate_id_fkey"
      columns: ["mandate_id"]
isOneToOne: false
      referencedRelation: "mandate"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_line_mandate_terms_id_fkey"
      columns: ["mandate_terms_id"]
isOneToOne: false
      referencedRelation: "mandate_terms"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_line_original_entry_id_fkey"
      columns: ["original_entry_id"]
isOneToOne: false
      referencedRelation: "ledger_entry"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_line_payment_id_fkey"
      columns: ["payment_id"]
isOneToOne: false
      referencedRelation: "payment"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_line_portfolio_id_fkey"
      columns: ["portfolio_id"]
isOneToOne: false
      referencedRelation: "portfolio"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_line_run_id_fkey"
      columns: ["run_id"]
isOneToOne: false
      referencedRelation: "remittance_run"
      referencedColumns: ["id"]
    }
                  ]
                },"remittance_line_repricing": {
                  Row: {
                    "commission_minor": number,"commission_reason": string | null,"commission_state": string,"invoice_id": string | null,"ledger_entry_id": string,"line_no": number,"parts": NonNullable<Json>,"pricing_run_id": string,"run_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "commission_minor": number,"commission_reason"?: string | null,"commission_state": string,"invoice_id"?: string | null,"ledger_entry_id": string,"line_no": number,"parts"?: NonNullable<Json>,"pricing_run_id": string,"run_id": string
                  }
                  Update: {
                    "commission_minor"?: number,"commission_reason"?: string | null,"commission_state"?: string,"invoice_id"?: string | null,"ledger_entry_id"?: string,"line_no"?: number,"parts"?: NonNullable<Json>,"pricing_run_id"?: string,"run_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "remittance_line_repricing_invoice_fk"
      columns: ["invoice_id"]
isOneToOne: false
      referencedRelation: "commission_invoice"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_line_repricing_ledger_entry_id_fkey"
      columns: ["ledger_entry_id"]
isOneToOne: false
      referencedRelation: "ledger_entry"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_line_repricing_pricing_run_id_fkey"
      columns: ["pricing_run_id"]
isOneToOne: false
      referencedRelation: "remittance_run"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_line_repricing_run_id_line_no_fkey"
      columns: ["run_id","line_no"]
isOneToOne: false
      referencedRelation: "remittance_line"
      referencedColumns: ["run_id","line_no"]
    }
                  ]
                },"remittance_run": {
                  Row: {
                    "advance_recovered_minor": number | null,"approval_requested_by": string | null,"approved_at": string | null,"approved_by": string | null,"blockers": (string)[],"booked_on": string | null,"cancel_reason": string | null,"cancelled_at": string | null,"cancelled_by": string | null,"client_organization_id": string,"commission_blockers": (string)[],"commission_taken_minor": number | null,"created_at": string,"created_by": string | null,"credit_ht_minor": number | null,"credit_ttc_minor": number | null,"credit_vat_minor": number | null,"currency": string,"earliest_deadline": string | null,"earliest_latest_execution_date": string | null,"engine_version": string | null,"gross_minor": number | null,"id": string,"inputs_hash": string | null,"invoice_ht_minor": number | null,"invoice_late": boolean,"invoice_ttc_minor": number | null,"invoice_vat_minor": number | null,"item_count": number,"job": string | null,"job_queued_at": string | null,"job_token": string | null,"known_at": string,"last_failure": Json | null,"late_reason": string | null,"line_count": number | null,"net_minor": number | null,"number": string,"organization_id": string,"payout_account_id": string | null,"payout_snapshot": Json | null,"prepared_at": string | null,"previous_run_id": string | null,"refund_minor": number | null,"requested_execution_date": string | null,"schedule_key": string | null,"service_from": string | null,"service_to": string | null,"settlement_minor": number | null,"settlement_plan": Json | null,"status": string,"transfer_id": string | null,"trigger": string,"unmeetable_count": number,"updated_at": string,"vat_rate": number | null,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "advance_recovered_minor"?: number | null,"approval_requested_by"?: string | null,"approved_at"?: string | null,"approved_by"?: string | null,"blockers"?: (string)[],"booked_on"?: string | null,"cancel_reason"?: string | null,"cancelled_at"?: string | null,"cancelled_by"?: string | null,"client_organization_id": string,"commission_blockers"?: (string)[],"commission_taken_minor"?: number | null,"created_at"?: string,"created_by"?: string | null,"credit_ht_minor"?: number | null,"credit_ttc_minor"?: number | null,"credit_vat_minor"?: number | null,"currency": string,"earliest_deadline"?: string | null,"earliest_latest_execution_date"?: string | null,"engine_version"?: string | null,"gross_minor"?: number | null,"id"?: string,"inputs_hash"?: string | null,"invoice_ht_minor"?: number | null,"invoice_late"?: boolean,"invoice_ttc_minor"?: number | null,"invoice_vat_minor"?: number | null,"item_count"?: number,"job"?: string | null,"job_queued_at"?: string | null,"job_token"?: string | null,"known_at": string,"last_failure"?: Json | null,"late_reason"?: string | null,"line_count"?: number | null,"net_minor"?: number | null,"number": string,"organization_id": string,"payout_account_id"?: string | null,"payout_snapshot"?: Json | null,"prepared_at"?: string | null,"previous_run_id"?: string | null,"refund_minor"?: number | null,"requested_execution_date"?: string | null,"schedule_key"?: string | null,"service_from"?: string | null,"service_to"?: string | null,"settlement_minor"?: number | null,"settlement_plan"?: Json | null,"status"?: string,"transfer_id"?: string | null,"trigger": string,"unmeetable_count"?: number,"updated_at"?: string,"vat_rate"?: number | null,"version"?: number
                  }
                  Update: {
                    "advance_recovered_minor"?: number | null,"approval_requested_by"?: string | null,"approved_at"?: string | null,"approved_by"?: string | null,"blockers"?: (string)[],"booked_on"?: string | null,"cancel_reason"?: string | null,"cancelled_at"?: string | null,"cancelled_by"?: string | null,"client_organization_id"?: string,"commission_blockers"?: (string)[],"commission_taken_minor"?: number | null,"created_at"?: string,"created_by"?: string | null,"credit_ht_minor"?: number | null,"credit_ttc_minor"?: number | null,"credit_vat_minor"?: number | null,"currency"?: string,"earliest_deadline"?: string | null,"earliest_latest_execution_date"?: string | null,"engine_version"?: string | null,"gross_minor"?: number | null,"id"?: string,"inputs_hash"?: string | null,"invoice_ht_minor"?: number | null,"invoice_late"?: boolean,"invoice_ttc_minor"?: number | null,"invoice_vat_minor"?: number | null,"item_count"?: number,"job"?: string | null,"job_queued_at"?: string | null,"job_token"?: string | null,"known_at"?: string,"last_failure"?: Json | null,"late_reason"?: string | null,"line_count"?: number | null,"net_minor"?: number | null,"number"?: string,"organization_id"?: string,"payout_account_id"?: string | null,"payout_snapshot"?: Json | null,"prepared_at"?: string | null,"previous_run_id"?: string | null,"refund_minor"?: number | null,"requested_execution_date"?: string | null,"schedule_key"?: string | null,"service_from"?: string | null,"service_to"?: string | null,"settlement_minor"?: number | null,"settlement_plan"?: Json | null,"status"?: string,"transfer_id"?: string | null,"trigger"?: string,"unmeetable_count"?: number,"updated_at"?: string,"vat_rate"?: number | null,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "remittance_run_approval_requested_by_fkey"
      columns: ["approval_requested_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_run_approved_by_fkey"
      columns: ["approved_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_run_cancelled_by_fkey"
      columns: ["cancelled_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_run_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_run_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_run_currency_fkey"
      columns: ["currency"]
isOneToOne: false
      referencedRelation: "currency"
      referencedColumns: ["code"]
    },{
      foreignKeyName: "remittance_run_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_run_payout_account_id_fkey"
      columns: ["payout_account_id"]
isOneToOne: false
      referencedRelation: "client_payout_account"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_run_previous_run_id_fkey"
      columns: ["previous_run_id"]
isOneToOne: false
      referencedRelation: "remittance_run"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_run_transfer_id_fkey"
      columns: ["transfer_id"]
isOneToOne: true
      referencedRelation: "bank_transfer"
      referencedColumns: ["id"]
    }
                  ]
                },"remittance_statement": {
                  Row: {
                    "client_organization_id": string,"created_at": string,"csv_document_id": string,"csv_sha256": string,"currency": string,"drawn_status": string,"file_count": number,"gross_minor": number,"issue_date": string,"known_at": string,"line_count": number,"net_minor": number,"number": string,"organization_id": string,"payload": NonNullable<Json>,"payload_sha256": string,"pdf_document_id": string,"pdf_sha256": string,"renderer_version": string,"run_id": string,"template_version": string
                  }
                  ComputedFields: never
                  Insert: {
                    "client_organization_id": string,"created_at"?: string,"csv_document_id": string,"csv_sha256": string,"currency": string,"drawn_status": string,"file_count": number,"gross_minor": number,"issue_date": string,"known_at": string,"line_count": number,"net_minor": number,"number": string,"organization_id": string,"payload": NonNullable<Json>,"payload_sha256": string,"pdf_document_id": string,"pdf_sha256": string,"renderer_version": string,"run_id": string,"template_version": string
                  }
                  Update: {
                    "client_organization_id"?: string,"created_at"?: string,"csv_document_id"?: string,"csv_sha256"?: string,"currency"?: string,"drawn_status"?: string,"file_count"?: number,"gross_minor"?: number,"issue_date"?: string,"known_at"?: string,"line_count"?: number,"net_minor"?: number,"number"?: string,"organization_id"?: string,"payload"?: NonNullable<Json>,"payload_sha256"?: string,"pdf_document_id"?: string,"pdf_sha256"?: string,"renderer_version"?: string,"run_id"?: string,"template_version"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "remittance_statement_client_organization_id_fkey"
      columns: ["client_organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_statement_csv_document_id_fkey"
      columns: ["csv_document_id"]
isOneToOne: true
      referencedRelation: "document"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_statement_currency_fkey"
      columns: ["currency"]
isOneToOne: false
      referencedRelation: "currency"
      referencedColumns: ["code"]
    },{
      foreignKeyName: "remittance_statement_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_statement_pdf_document_id_fkey"
      columns: ["pdf_document_id"]
isOneToOne: true
      referencedRelation: "document"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "remittance_statement_run_id_fkey"
      columns: ["run_id"]
isOneToOne: true
      referencedRelation: "remittance_run"
      referencedColumns: ["id"]
    }
                  ]
                },"servicer_billing_settings": {
                  Row: {
                    "bank_cutoff": NonNullable<Json>,"created_at": string,"invoice_prefix": string,"organization_id": string,"own_bank_account_id": string | null,"penalty_text": string,"updated_at": string,"updated_by": string | null,"vat_on_debits": boolean,"version": number
                  }
                  ComputedFields: never
                  Insert: {
                    "bank_cutoff"?: NonNullable<Json>,"created_at"?: string,"invoice_prefix"?: string,"organization_id": string,"own_bank_account_id"?: string | null,"penalty_text"?: string,"updated_at"?: string,"updated_by"?: string | null,"vat_on_debits"?: boolean,"version"?: number
                  }
                  Update: {
                    "bank_cutoff"?: NonNullable<Json>,"created_at"?: string,"invoice_prefix"?: string,"organization_id"?: string,"own_bank_account_id"?: string | null,"penalty_text"?: string,"updated_at"?: string,"updated_by"?: string | null,"vat_on_debits"?: boolean,"version"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "servicer_billing_settings_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: true
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "servicer_billing_settings_own_bank_account_id_fkey"
      columns: ["own_bank_account_id"]
isOneToOne: false
      referencedRelation: "bank_account"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "servicer_billing_settings_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    }
                  ]
                },"transfer_file": {
                  Row: {
                    "cash_check": NonNullable<Json>,"close_attestation": string | null,"close_reason": string | null,"closed_at": string | null,"closed_by": string | null,"created_at": string,"created_at_iso": string,"created_by": string | null,"ctrl_sum_minor": number,"currency": string,"debtor_bank_account_id": string,"debtor_bic": string | null,"debtor_iban": string,"debtor_name": string,"download_count": number,"error": string | null,"file_sha256": string | null,"first_downloaded_at": string | null,"first_downloaded_by": string | null,"first_execution_date": string,"generated_at": string | null,"held": NonNullable<Json>,"id": string,"initiating_party": string,"job_token": string,"last_execution_date": string,"late_reason": string | null,"msg_id": string,"nb_of_txs": number,"number": string,"organization_id": string,"pain_version": string,"renderer_version": string | null,"sent_marked_at": string | null,"sent_marked_by": string | null,"size_bytes": number | null,"status": string,"storage_path": string | null,"superseded_by": string | null,"updated_at": string,"version": number,"xsd_validated": boolean | null
                  }
                  ComputedFields: never
                  Insert: {
                    "cash_check": NonNullable<Json>,"close_attestation"?: string | null,"close_reason"?: string | null,"closed_at"?: string | null,"closed_by"?: string | null,"created_at"?: string,"created_at_iso": string,"created_by"?: string | null,"ctrl_sum_minor": number,"currency"?: string,"debtor_bank_account_id": string,"debtor_bic"?: string | null,"debtor_iban": string,"debtor_name": string,"download_count"?: number,"error"?: string | null,"file_sha256"?: string | null,"first_downloaded_at"?: string | null,"first_downloaded_by"?: string | null,"first_execution_date": string,"generated_at"?: string | null,"held"?: NonNullable<Json>,"id"?: string,"initiating_party": string,"job_token"?: string,"last_execution_date": string,"late_reason"?: string | null,"msg_id": string,"nb_of_txs": number,"number": string,"organization_id": string,"pain_version": string,"renderer_version"?: string | null,"sent_marked_at"?: string | null,"sent_marked_by"?: string | null,"size_bytes"?: number | null,"status"?: string,"storage_path"?: string | null,"superseded_by"?: string | null,"updated_at"?: string,"version"?: number,"xsd_validated"?: boolean | null
                  }
                  Update: {
                    "cash_check"?: NonNullable<Json>,"close_attestation"?: string | null,"close_reason"?: string | null,"closed_at"?: string | null,"closed_by"?: string | null,"created_at"?: string,"created_at_iso"?: string,"created_by"?: string | null,"ctrl_sum_minor"?: number,"currency"?: string,"debtor_bank_account_id"?: string,"debtor_bic"?: string | null,"debtor_iban"?: string,"debtor_name"?: string,"download_count"?: number,"error"?: string | null,"file_sha256"?: string | null,"first_downloaded_at"?: string | null,"first_downloaded_by"?: string | null,"first_execution_date"?: string,"generated_at"?: string | null,"held"?: NonNullable<Json>,"id"?: string,"initiating_party"?: string,"job_token"?: string,"last_execution_date"?: string,"late_reason"?: string | null,"msg_id"?: string,"nb_of_txs"?: number,"number"?: string,"organization_id"?: string,"pain_version"?: string,"renderer_version"?: string | null,"sent_marked_at"?: string | null,"sent_marked_by"?: string | null,"size_bytes"?: number | null,"status"?: string,"storage_path"?: string | null,"superseded_by"?: string | null,"updated_at"?: string,"version"?: number,"xsd_validated"?: boolean | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "transfer_file_bank_fk"
      columns: ["debtor_bank_account_id","organization_id","currency"]
isOneToOne: false
      referencedRelation: "bank_account"
      referencedColumns: ["id","organization_id","currency"]
    },{
      foreignKeyName: "transfer_file_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "transfer_file_first_downloaded_by_fkey"
      columns: ["first_downloaded_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "transfer_file_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "transfer_file_sent_marked_by_fkey"
      columns: ["sent_marked_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "transfer_file_superseded_by_fkey"
      columns: ["superseded_by"]
isOneToOne: false
      referencedRelation: "transfer_file"
      referencedColumns: ["id"]
    }
                  ]
                },"transfer_file_download": {
                  Row: {
                    "downloaded_at": string,"downloaded_by": string,"file_id": string,"id": string,"n": number,"organization_id": string,"sha256": string,"warning_acknowledged": boolean
                  }
                  ComputedFields: never
                  Insert: {
                    "downloaded_at"?: string,"downloaded_by": string,"file_id": string,"id"?: string,"n": number,"organization_id": string,"sha256": string,"warning_acknowledged": boolean
                  }
                  Update: {
                    "downloaded_at"?: string,"downloaded_by"?: string,"file_id"?: string,"id"?: string,"n"?: number,"organization_id"?: string,"sha256"?: string,"warning_acknowledged"?: boolean
                  }
                  Relationships: [
                    {
      foreignKeyName: "transfer_file_download_downloaded_by_fkey"
      columns: ["downloaded_by"]
isOneToOne: false
      referencedRelation: "app_user"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "transfer_file_download_file_id_fkey"
      columns: ["file_id"]
isOneToOne: false
      referencedRelation: "transfer_file"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "transfer_file_download_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    }
                  ]
                },"transfer_file_item": {
                  Row: {
                    "execution_date": string,"file_id": string,"late": boolean,"organization_id": string,"pmt_inf_id": string,"seq": number,"transfer_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "execution_date": string,"file_id": string,"late"?: boolean,"organization_id": string,"pmt_inf_id": string,"seq": number,"transfer_id": string
                  }
                  Update: {
                    "execution_date"?: string,"file_id"?: string,"late"?: boolean,"organization_id"?: string,"pmt_inf_id"?: string,"seq"?: number,"transfer_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "transfer_file_item_file_id_fkey"
      columns: ["file_id"]
isOneToOne: false
      referencedRelation: "transfer_file"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "transfer_file_item_organization_id_fkey"
      columns: ["organization_id"]
isOneToOne: false
      referencedRelation: "organization"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "transfer_file_item_transfer_id_fkey"
      columns: ["transfer_id"]
isOneToOne: false
      referencedRelation: "bank_transfer"
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
                },"vat_rate": {
                  Row: {
                    "code": string,"legal_ref": string,"legal_url": string,"rate": number,"review_due_on": string | null,"reviewed_by": string | null,"reviewed_on": string | null,"territory": string,"valid_from": string,"valid_to": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "code": string,"legal_ref": string,"legal_url": string,"rate": number,"review_due_on"?: string | null,"reviewed_by"?: string | null,"reviewed_on"?: string | null,"territory": string,"valid_from": string,"valid_to"?: string | null
                  }
                  Update: {
                    "code"?: string,"legal_ref"?: string,"legal_url"?: string,"rate"?: number,"review_due_on"?: string | null,"reviewed_by"?: string | null,"reviewed_on"?: string | null,"territory"?: string,"valid_from"?: string,"valid_to"?: string | null
                  }
                  Relationships: [
                    
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
{ Args: { "p_idempotency_key": string,"p_items": Json }; Returns: Json
                           },
"account_balances":
{ Args: { "p_account_id": string,"p_as_of"?: string,"p_known_at"?: string }; Returns: {
              "balance_minor": number,"claim_item_id": string,"component": string,"currency": string
            }[]
                           },
"account_detail":
{ Args: { "p_account_id": string }; Returns: Json
                           },
"accounting_export_documents":
{ Args: { "p_after"?: string,"p_from": string,"p_limit"?: number,"p_to": string }; Returns: {
              "client_name": string,"client_siren": string,"corrects": string,"due_date": string,"ht_minor": number,"issue_date": string,"kind": string,"mandate": string,"number": string,"open_minor": number,"page_key": string,"run_number": string,"service_from": string,"service_to": string,"settled_minor": number,"settlement": string,"settlements": string,"ttc_minor": number,"vat_book": string,"vat_minor": number,"vat_rate": number
            }[]
                           },
"accounting_export_entries":
{ Args: { "p_after"?: string,"p_from": string,"p_limit"?: number,"p_to": string }; Returns: {
              "account_number": string,"book": string,"client_name": string,"credit_minor": number,"currency": string,"debit_minor": number,"effective_date": string,"entry_id": string,"entry_type": string,"page_key": string,"posted_at": string,"source_ref": string,"source_type": string
            }[]
                           },
"add_boarding_file":
{ Args: { "p_batch_id": string,"p_file_name": string,"p_sha256": string,"p_size_bytes": number }; Returns: Json
                           },
"allocate_payment":
{ Args: { "p_account_id": string,"p_evidence_document_id": string,"p_expected_reason": string,"p_idempotency_key": string,"p_payment_id": string,"p_reason": string }; Returns: Json
                           },
"apply_credit_note":
{ Args: { "p_account_id": string,"p_idempotency_key": string,"p_proposal_key": string }; Returns: Json
                           },
"approve_mapping":
{ Args: { "p_batch_id": string,"p_overrides"?: Json }; Returns: undefined
                           },
"approve_remittance_runs":
{ Args: { "p_idempotency_key": string,"p_items": Json,"p_late_reason"?: string,"p_requested_execution_date"?: string }; Returns: Json
                           },
"assign_payment":
{ Args: { "p_designation": Json,"p_idempotency_key": string,"p_payment_id": string,"p_reason": string,"p_splits": Json }; Returns: Json
                           },
"billing_identity_gaps":
{ Args: { "p_organization_id": string }; Returns: (string)[]
                           },
"boarding_batch_readiness":
{ Args: { "p_batch_id": string }; Returns: (string)[]
                           },
"cancel_refund":
{ Args: { "p_idempotency_key": string,"p_reason": string,"p_refund_request_id": string }; Returns: Json
                           },
"cancel_remittance_run":
{ Args: { "p_attestation"?: string,"p_expected_version": number,"p_idempotency_key": string,"p_reason": string,"p_run_id": string }; Returns: Json
                           },
"cancel_top_up":
{ Args: { "p_idempotency_key": string,"p_reason": string,"p_transfer_id": string }; Returns: Json
                           },
"cancel_transfer_file":
{ Args: { "p_attestation"?: string,"p_expected_version": number,"p_file_id": string,"p_idempotency_key": string,"p_reason": string }; Returns: Json
                           },
"clear_payee_name_mismatch":
{ Args: { "p_check_id": string,"p_idempotency_key": string,"p_reason": string }; Returns: Json
                           },
"client_money_balances":
{ Args: { "p_as_of"?: string,"p_client_organization_id": string,"p_known_at"?: string }; Returns: {
              "currency": string,"held_minor": number,"payable_minor": number,"unallocated_minor": number
            }[]
                           },
"client_payment_feed":
{ Args: { "p_after"?: string,"p_client": string,"p_limit"?: number }; Returns: {
              "account_id": string,"amount_minor": string,"booking_date": string,"created_at": string,"currency": string,"cursor": string,"debtor_name": string,"delivered_at": string,"effective_date": string,"file_reference": string,"first_view": boolean,"kind": string,"lines": Json,"notification_id": string,"reason": string,"receipt_id": string,"receipt_kind": string,"receipt_number": string,"receipt_version": number
            }[]
                           },
"client_readiness":
{ Args: { "p_client_organization_id": string }; Returns: {
              "blockers": (string)[],"portfolio_id": string,"portfolio_name": string
            }[]
                           },
"client_remittance_summary":
{ Args: { "p_client_organization_id": string }; Returns: Json
                           },
"close_bank_account":
{ Args: { "p_bank_account_id": string,"p_idempotency_key": string,"p_reason": string }; Returns: undefined
                           },
"commission_invoice_detail":
{ Args: { "p_invoice_id": string }; Returns: Json
                           },
"commission_invoice_files":
{ Args: { "p_after"?: string,"p_invoice_id": string,"p_limit"?: number }; Returns: {
              "file_id": string,"file_ref": string,"open_minor": number,"page_key": string,"tier_key": string
            }[]
                           },
"commit_boarding_batch":
{ Args: { "p_batch_id": string,"p_override_reason"?: string }; Returns: undefined
                           },
"confirm_boarding_batch":
{ Args: { "p_batch_id": string }; Returns: undefined
                           },
"confirm_payout_account":
{ Args: { "p_iban_typed": string,"p_idempotency_key": string,"p_payout_account_id": string }; Returns: Json
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
"credit_note_preview":
{ Args: { "p_account_id"?: string,"p_amount_ht_text": string,"p_invoice_id": string }; Returns: Json
                           },
"custom_access_token_hook":
{ Args: { "event": Json }; Returns: Json
                           },
"debit_link_options":
{ Args: { "p_bank_transaction_id": string }; Returns: Json
                           },
"debit_queue":
{ Args: { "p_limit"?: number,"p_offset"?: number,"p_tab"?: string }; Returns: {
              "age_days": number,"amount_minor": string,"bank_account_id": string,"bank_transaction_id": string,"booking_date": string,"candidates": Json,"counterparty_iban_end": string,"counterparty_name": string,"currency": string,"decided_at": string,"decided_payment_id": string,"decision": string,"direction": string,"end_to_end_id": string,"held_kind": string,"kind": string,"original_end_to_end_id": string,"remittance_text": string,"return_reason": string,"review_reason": string,"statement_id": string,"total": number
            }[]
                           },
"discard_remittance_run":
{ Args: { "p_expected_version": number,"p_idempotency_key": string,"p_reason": string,"p_run_id": string }; Returns: Json
                           },
"forward_payment":
{ Args: { "p_client_organization_id": string,"p_evidence_document_id": string,"p_expected_minor": string,"p_idempotency_key": string,"p_payment_id": string,"p_reason": string }; Returns: Json
                           },
"generate_transfer_file":
{ Args: { "p_bank_account_id": string,"p_idempotency_key": string,"p_late_reason"?: string }; Returns: Json
                           },
"issue_credit_note":
{ Args: { "p_account_id"?: string,"p_amount_ht_text": string,"p_expected_remaining_text": string,"p_idempotency_key": string,"p_invoice_id": string,"p_reason": string,"p_reason_code": string }; Returns: Json
                           },
"ledger_balance":
{ Args: { "p_as_of"?: string,"p_known_at"?: string,"p_ledger_account_id": string }; Returns: number
                           },
"lift_account_hold":
{ Args: { "p_hold_id": string,"p_idempotency_key": string,"p_reason": string }; Returns: undefined
                           },
"link_debit":
{ Args: { "p_bank_transaction_id": string,"p_expected_left_minor": string,"p_idempotency_key": string,"p_kind": string,"p_payment_id": string,"p_reason": string,"p_refund_request_id": string }; Returns: Json
                           },
"mark_transfer_file_sent":
{ Args: { "p_expected_version": number,"p_file_id": string,"p_idempotency_key": string }; Returns: Json
                           },
"match_queue_accounts":
{ Args: { "p_account_ids": (string)[] }; Returns: {
              "account_id": string,"balance_minor": string,"client_name": string,"currency": string,"debtor_name": string,"external_ref": string,"holds": (string)[],"pending_minor": string,"rf": string,"servicing_start": string,"status": string
            }[]
                           },
"payment_detail":
{ Args: { "p_payment_id": string }; Returns: Json
                           },
"payment_queue":
{ Args: { "p_client"?: string,"p_limit"?: number,"p_max_minor"?: number,"p_min_days"?: number,"p_min_minor"?: number,"p_offset"?: number,"p_reason"?: string,"p_tab"?: string }; Returns: {
              "account_id": string,"age_days": number,"amount_minor": string,"booking_date": string,"candidate_account_id": string,"client_organization_id": string,"creditor_reference": string,"currency": string,"forwarded": boolean,"match_method": string,"matched_at": string,"payer_iban_end": string,"payer_name": string,"payment_id": string,"remittance_text": string,"review_reason": string,"status": string,"total": number
            }[]
                           },
"payout_accounts":
{ Args: { "p_client_organization_id": string }; Returns: {
              "bic": string,"closed_at": string,"closed_reason": string,"confirmed_at": string,"confirmed_by_name": string,"confirmed_via": string,"currency": string,"evidence_document_id": string,"holder_name": string,"iban_last4": string,"iban_masked": string,"id": string,"kind": string,"paid_before": boolean,"proposed_at": string,"proposed_by_me": boolean,"proposed_by_name": string,"status": string
            }[]
                           },
"place_account_hold":
{ Args: { "p_account_id": string,"p_evidence_document_id": string,"p_idempotency_key": string,"p_kind": string,"p_legal_basis": string,"p_reason": string }; Returns: string
                           },
"propose_payout_account":
{ Args: { "p_bic": string,"p_client_organization_id": string,"p_currency": string,"p_evidence_document_id": string,"p_holder_name": string,"p_iban": string,"p_idempotency_key": string,"p_kind"?: string }; Returns: Json
                           },
"receipt_job_pending":
{ Args: { "p_payment_id": string }; Returns: boolean
                           },
"record_client_status_event":
{ Args: { "p_client_organization_id": string,"p_effective_date": string,"p_evidence_document_id": string,"p_idempotency_key": string,"p_kind": string,"p_note": string,"p_payout_account_id"?: string }; Returns: Json
                           },
"record_direct_payment":
{ Args: { "p_account_id": string,"p_amount_minor": string,"p_evidence_document_id": string,"p_idempotency_key": string,"p_item_ids": (string)[],"p_paid_on": string,"p_reason": string }; Returns: Json
                           },
"record_payee_name_mismatch":
{ Args: { "p_bank_name": string,"p_idempotency_key": string,"p_note": string,"p_result": string,"p_transfer_id": string }; Returns: Json
                           },
"refresh_remittance_run":
{ Args: { "p_expected_version": number,"p_idempotency_key": string,"p_run_id": string }; Returns: Json
                           },
"register_bank_account":
{ Args: { "p_bic"?: string,"p_currency": string,"p_feed": string,"p_iban": string,"p_idempotency_key": string,"p_label": string,"p_opened_on"?: string,"p_organization_id": string,"p_purpose"?: string }; Returns: string
                           },
"register_client_document":
{ Args: { "p_client_organization_id": string,"p_file_name": string,"p_idempotency_key": string,"p_kind": string,"p_mime_type": string,"p_sha256": string,"p_storage_path": string }; Returns: Json
                           },
"reject_payout_account":
{ Args: { "p_idempotency_key": string,"p_payout_account_id": string,"p_reason": string }; Returns: Json
                           },
"release_hold_payment":
{ Args: { "p_evidence_document_id": string,"p_idempotency_key": string,"p_payment_id": string,"p_reason": string }; Returns: Json
                           },
"release_own_credit":
{ Args: { "p_bank_transaction_id": string,"p_idempotency_key": string,"p_reason": string }; Returns: Json
                           },
"remittance_overview":
{ Args: { "p_tab"?: string }; Returns: Json
                           },
"remittance_run_detail":
{ Args: { "p_limit"?: number,"p_offset"?: number,"p_run_id": string }; Returns: Json
                           },
"request_payment_checks":
{ Args: { "p_organization_id": string }; Returns: Json
                           },
"request_refund":
{ Args: { "p_amount_minor": string,"p_execution_mode"?: string,"p_expected_left_minor": string,"p_expected_review_reason": string,"p_idempotency_key": string,"p_payee_iban": string,"p_payee_name": string,"p_payment_id": string,"p_reason": string,"p_reason_code": string }; Returns: Json
                           },
"request_remittance_run":
{ Args: { "p_client_organization_id": string,"p_currency"?: string,"p_idempotency_key": string }; Returns: Json
                           },
"request_top_up":
{ Args: { "p_amount_minor": string,"p_client_funds_bank_account_id": string,"p_idempotency_key": string,"p_own_bank_account_id": string,"p_reason": string,"p_requested_execution_date"?: string }; Returns: Json
                           },
"resolve_duplicate":
{ Args: { "p_bank_transaction_id": string,"p_idempotency_key": string,"p_is_duplicate": boolean,"p_reason": string }; Returns: Json
                           },
"retire_payment_reference":
{ Args: { "p_idempotency_key": string,"p_reason": string,"p_reference_id": string }; Returns: string
                           },
"retire_payout_account":
{ Args: { "p_idempotency_key": string,"p_payout_account_id": string,"p_reason": string }; Returns: Json
                           },
"reverse_allocation":
{ Args: { "p_account_id": string,"p_entry_ids": (string)[],"p_idempotency_key": string,"p_payment_id": string,"p_reason": string }; Returns: Json
                           },
"rollback_boarding_batch":
{ Args: { "p_batch_id": string,"p_reason": string }; Returns: undefined
                           },
"search_payment_files":
{ Args: { "p_payment_id": string,"p_query": string }; Returns: {
              "account_id": string,"balance_minor": string,"client_name": string,"currency": string,"debtor_name": string,"external_ref": string,"found_by": string,"holds": (string)[],"pending_minor": string,"rf": string,"servicing_start": string,"status": string
            }[]
                           },
"set_allocation_policy":
{ Args: { "p_accessory_rank": string,"p_client_organization_id": string,"p_effective_from": string,"p_idempotency_key": string,"p_organization_id": string,"p_portfolio_id": string,"p_reason": string,"p_unclassified": string }; Returns: string
                           },
"set_bank_account_pain_version":
{ Args: { "p_bank_account_id": string,"p_idempotency_key": string,"p_version": string }; Returns: Json
                           },
"set_billing_identity":
{ Args: { "p_expected_version": number,"p_idempotency_key": string,"p_identity": Json,"p_organization_id": string }; Returns: Json
                           },
"set_control_totals":
{ Args: { "p_batch_id": string,"p_rows": number,"p_total_minor": number }; Returns: undefined
                           },
"set_mandate_insurance_clause":
{ Args: { "p_clause_ref": string,"p_expected": string,"p_idempotency_key": string,"p_mandate_id": string }; Returns: Json
                           },
"set_mandate_terms":
{ Args: { "p_commission_clause_ref": string,"p_commission_schedule": Json,"p_document_id": string,"p_expected_latest_id": string,"p_idempotency_key": string,"p_mandate_id": string,"p_remittance_clause_ref": string,"p_remittance_max_days": number,"p_remittance_terms": Json,"p_valid_from": string }; Returns: Json
                           },
"set_servicer_billing_settings":
{ Args: { "p_expected_version": number,"p_idempotency_key": string,"p_organization_id": string,"p_settings": Json }; Returns: Json
                           },
"statement_match_counts":
{ Args: { "p_statement_ids": (string)[] }; Returns: {
              "automatic": number,"payments": number,"statement_id": string,"to_review": number,"waiting": number
            }[]
                           },
"submit_boarding_batch":
{ Args: { "p_batch_id": string }; Returns: number
                           },
"submit_statement_import":
{ Args: { "p_idempotency_key": string,"p_statement_id": string }; Returns: string
                           },
"transfer_file_detail":
{ Args: { "p_after_seq"?: number,"p_file_id": string,"p_limit"?: number }; Returns: Json
                           },
"transfer_file_download":
{ Args: { "p_acknowledged"?: boolean,"p_file_id": string,"p_sha256": string }; Returns: Json
                           },
"transfer_overview":
{ Args: Record<PropertyKey, never>; Returns: Json
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
