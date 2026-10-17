//! Small system-SQLite boundary. SQLite owns locking/WAL/crash consistency;
//! all dynamic text is quoted as a SQL string literal, never SQL syntax.
use serde_json::Value;
use std::{
    ffi::{CStr, CString, c_char, c_int, c_void},
    path::Path,
    ptr,
};
#[link(name = "sqlite3")]
unsafe extern "C" {
    fn sqlite3_open_v2(
        name: *const c_char,
        db: *mut *mut c_void,
        flags: c_int,
        vfs: *const c_char,
    ) -> c_int;
    fn sqlite3_close(db: *mut c_void) -> c_int;
    fn sqlite3_exec(
        db: *mut c_void,
        sql: *const c_char,
        callback: Option<
            unsafe extern "C" fn(*mut c_void, c_int, *mut *mut c_char, *mut *mut c_char) -> c_int,
        >,
        context: *mut c_void,
        error: *mut *mut c_char,
    ) -> c_int;
    fn sqlite3_errmsg(db: *mut c_void) -> *const c_char;
    fn sqlite3_busy_timeout(db: *mut c_void, ms: c_int) -> c_int;
}
pub struct Database {
    raw: *mut c_void,
}
// Opened with SQLITE_OPEN_FULLMUTEX; the enclosing Core is additionally held
// behind one mutex. No statement or callback escapes a synchronous call.
unsafe impl Send for Database {}
fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}
unsafe extern "C" fn collect(
    context: *mut c_void,
    count: c_int,
    columns: *mut *mut c_char,
    _names: *mut *mut c_char,
) -> c_int {
    if count > 0 {
        unsafe {
            let column = *columns;
            if !column.is_null() {
                let values = &mut *context.cast::<Vec<String>>();
                values.push(CStr::from_ptr(column).to_string_lossy().into_owned());
            }
        }
    }
    0
}
impl Database {
    pub fn open(path: &Path) -> Result<Self, String> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let name = CString::new(path.to_string_lossy().as_bytes()).map_err(|e| e.to_string())?;
        let mut raw = ptr::null_mut();
        let result =
            unsafe { sqlite3_open_v2(name.as_ptr(), &mut raw, 2 | 4 | 0x10000, ptr::null()) };
        if result != 0 {
            if !raw.is_null() {
                unsafe {
                    sqlite3_close(raw);
                }
            }
            return Err("Cannot open the RELAY job database".into());
        }
        let db = Self { raw };
        unsafe {
            sqlite3_busy_timeout(raw, 2500);
        }
        db.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")?;
        let version = db
            .query("PRAGMA user_version")?
            .first()
            .cloned()
            .unwrap_or_default();
        if version != "0" && version != "1" && version != "2" {
            return Err("This database was created by a newer RELAY version".into());
        }
        db.execute("CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY,value TEXT NOT NULL); CREATE TABLE IF NOT EXISTS events(sequence INTEGER PRIMARY KEY AUTOINCREMENT,payload TEXT NOT NULL); PRAGMA user_version=2;")?;
        Ok(db)
    }
    pub fn execute(&self, sql: &str) -> Result<(), String> {
        let sql = CString::new(sql).map_err(|e| e.to_string())?;
        if unsafe {
            sqlite3_exec(
                self.raw,
                sql.as_ptr(),
                None,
                ptr::null_mut(),
                ptr::null_mut(),
            )
        } != 0
        {
            return Err(unsafe { CStr::from_ptr(sqlite3_errmsg(self.raw)) }
                .to_string_lossy()
                .into_owned());
        }
        Ok(())
    }
    pub fn query(&self, sql: &str) -> Result<Vec<String>, String> {
        let mut rows = Vec::<String>::new();
        let sql = CString::new(sql).map_err(|e| e.to_string())?;
        let result = unsafe {
            sqlite3_exec(
                self.raw,
                sql.as_ptr(),
                Some(collect),
                (&mut rows as *mut Vec<String>).cast(),
                ptr::null_mut(),
            )
        };
        if result != 0 {
            return Err(unsafe { CStr::from_ptr(sqlite3_errmsg(self.raw)) }
                .to_string_lossy()
                .into_owned());
        }
        Ok(rows)
    }
    pub fn get(&self, key: &str) -> Result<Option<Value>, String> {
        self.query(&format!("SELECT value FROM kv WHERE key={}", quote(key)))?
            .first()
            .map(|v| serde_json::from_str(v).map_err(|e| e.to_string()))
            .transpose()
    }
    pub fn put(&self, key: &str, value: &impl serde::Serialize) -> Result<(), String> {
        let json = serde_json::to_string(value).map_err(|e| e.to_string())?;
        self.execute(&format!("INSERT INTO kv(key,value) VALUES({},{}) ON CONFLICT(key) DO UPDATE SET value=excluded.value",quote(key),quote(&json)))
    }
    pub fn values(&self, prefix: &str) -> Result<Vec<Value>, String> {
        self.query(&format!(
            "SELECT value FROM kv WHERE substr(key,1,{})={} ORDER BY key",
            prefix.len(),
            quote(prefix)
        ))?
        .iter()
        .map(|v| serde_json::from_str(v).map_err(|e| e.to_string()))
        .collect()
    }
    pub fn event(&self, event: Value) -> Result<(), String> {
        self.execute(&format!(
            "INSERT INTO events(payload) VALUES({})",
            quote(&event.to_string())
        ))
    }
    pub fn events(&self) -> Result<Vec<Value>, String> {
        self.query("SELECT payload FROM events ORDER BY sequence DESC LIMIT 100")?
            .iter()
            .map(|v| serde_json::from_str(v).map_err(|e| e.to_string()))
            .collect()
    }
    pub fn transaction<T>(
        &self,
        operation: impl FnOnce() -> Result<T, String>,
    ) -> Result<T, String> {
        self.execute("BEGIN IMMEDIATE")?;
        match operation() {
            Ok(value) => {
                if let Err(e) = self.execute("COMMIT") {
                    let _ = self.execute("ROLLBACK");
                    return Err(e);
                }
                Ok(value)
            }
            Err(e) => {
                let _ = self.execute("ROLLBACK");
                Err(e)
            }
        }
    }
}
impl Drop for Database {
    fn drop(&mut self) {
        unsafe {
            sqlite3_close(self.raw);
        }
    }
}
