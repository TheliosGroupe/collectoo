
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
                },"claim_item": {
                  Row: {
                    "account_id": string,"created_at": string,"currency": string,"due_date": string | null,"id": string,"issue_date": string | null,"kind": string,"original_minor": number,"ref": string
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id": string,"created_at"?: string,"currency"?: string,"due_date"?: string | null,"id"?: string,"issue_date"?: string | null,"kind": string,"original_minor": number,"ref": string
                  }
                  Update: {
                    "account_id"?: string,"created_at"?: string,"currency"?: string,"due_date"?: string | null,"id"?: string,"issue_date"?: string | null,"kind"?: string,"original_minor"?: number,"ref"?: string
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
                },"document": {
                  Row: {
                    "account_id": string | null,"client_organization_id": string,"created_at": string,"id": string,"kind": string,"mime_type": string,"organization_id": string,"party_id": string | null,"sha256": string,"storage_bucket": string,"storage_path": string
                  }
                  ComputedFields: never
                  Insert: {
                    "account_id"?: string | null,"client_organization_id": string,"created_at"?: string,"id"?: string,"kind": string,"mime_type": string,"organization_id": string,"party_id"?: string | null,"sha256": string,"storage_bucket"?: string,"storage_path": string
                  }
                  Update: {
                    "account_id"?: string | null,"client_organization_id"?: string,"created_at"?: string,"id"?: string,"kind"?: string,"mime_type"?: string,"organization_id"?: string,"party_id"?: string | null,"sha256"?: string,"storage_bucket"?: string,"storage_path"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "document_account_id_fkey"
      columns: ["account_id"]
isOneToOne: false
      referencedRelation: "account"
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
                    "birth_date": string | null,"client_organization_id": string,"created_at": string,"display_name": string,"first_name": string | null,"id": string,"kind": string,"last_name": string | null,"legal_form": string | null,"organization_id": string,"seller_ref": string | null,"source_attributes": NonNullable<Json>,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "birth_date"?: string | null,"client_organization_id": string,"created_at"?: string,"display_name": string,"first_name"?: string | null,"id"?: string,"kind": string,"last_name"?: string | null,"legal_form"?: string | null,"organization_id": string,"seller_ref"?: string | null,"source_attributes"?: NonNullable<Json>,"updated_at"?: string
                  }
                  Update: {
                    "birth_date"?: string | null,"client_organization_id"?: string,"created_at"?: string,"display_name"?: string,"first_name"?: string | null,"id"?: string,"kind"?: string,"last_name"?: string | null,"legal_form"?: string | null,"organization_id"?: string,"seller_ref"?: string | null,"source_attributes"?: NonNullable<Json>,"updated_at"?: string
                  }
                  Relationships: [
                    {
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
                }
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "create_portfolio":
{ Args: { "p_client_organization_id": string,"p_default_claim_type"?: string,"p_idempotency_key": string,"p_name": string }; Returns: string
                           },
"custom_access_token_hook":
{ Args: { "event": Json }; Returns: Json
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
