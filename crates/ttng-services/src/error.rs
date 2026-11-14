use std::fmt;

/// What went wrong, in words the apps can show as they are.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ServiceError {
    /// The service couldn't be reached.
    Network(String),
    /// The service said no (its own words), with the HTTP status.
    Refused { status: u16, message: String },
    /// Signed out, or the session ended elsewhere.
    SignedOut(String),
    /// An answer the app doesn't understand.
    Unexpected(String),
}

impl fmt::Display for ServiceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ServiceError::Network(m) | ServiceError::SignedOut(m) | ServiceError::Unexpected(m) => f.write_str(m),
            ServiceError::Refused { message, .. } => f.write_str(message),
        }
    }
}

impl std::error::Error for ServiceError {}

pub type Result<T> = std::result::Result<T, ServiceError>;
