/* Supabase 連線設定。這兩個值可以公開：anon／publishable 金鑰本來就設計給瀏覽器使用，
   資料安全由資料庫的 RLS 權限規則負責。絕對不要把 service_role 或 secret 金鑰放在這裡。 */
window.CPA_CONFIG = {
  supabaseUrl: "https://ybaurmalufeavjbcacra.supabase.co",
  supabaseAnonKey: "sb_publishable_hnHQ6VQmupdPY8hE2v-0UA_3EAaRuwn"
};
