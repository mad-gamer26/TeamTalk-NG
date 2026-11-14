use std::fmt;

/// What went wrong, in words the apps can show as they are.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    /// Not connected (or not logged in) to a server.
    NotConnected,
    /// The server, or the connection, didn't answer in time.
    Timeout,
    /// The connection couldn't be made, or broke.
    Connection(String),
    /// The server refused a command: its error number and message.
    Server { code: i32, message: String },
    /// The SDK refused a call (bad arguments, or not possible now).
    Refused(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::NotConnected => write!(f, "Not connected to a server."),
            Error::Timeout => write!(f, "The server didn't answer in time."),
            Error::Connection(m) => write!(f, "{m}"),
            Error::Server { message, .. } => write!(f, "{message}"),
            Error::Refused(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;
