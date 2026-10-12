//! Email for NG Account: the codes that finish signing up and reset a
//! password. Sent through an SMTP relay, or written to a folder in tests.

use std::path::PathBuf;

use anyhow::{Context, bail};
use lettre::message::Mailbox;
use lettre::transport::smtp::authentication::Credentials;
use lettre::{AsyncSmtpTransport, AsyncTransport, Message, Tokio1Executor};

use crate::config::{MailConfig, MailMode};

pub enum Mailer {
    None,
    Smtp { transport: Box<AsyncSmtpTransport<Tokio1Executor>>, from: Mailbox },
    Outbox { dir: PathBuf },
}

/// What a code is for, which decides the email's words.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodePurpose {
    SignUp,
    Reset,
}

impl CodePurpose {
    pub fn as_str(self) -> &'static str {
        match self {
            CodePurpose::SignUp => "signup",
            CodePurpose::Reset => "reset",
        }
    }
}

impl Mailer {
    pub fn new(cfg: &MailConfig) -> anyhow::Result<Mailer> {
        Ok(match cfg.mode {
            MailMode::None => Mailer::None,
            MailMode::Outbox => {
                let dir = cfg.outbox.clone().context("[mail] outbox is not set")?;
                std::fs::create_dir_all(&dir).with_context(|| format!("Could not create {}", dir.display()))?;
                Mailer::Outbox { dir }
            }
            MailMode::Smtp => {
                let smtp = cfg.smtp.as_ref().context("[mail.smtp] is not set up")?;
                let password = std::fs::read_to_string(&smtp.password_file)
                    .with_context(|| format!("Could not read {}", smtp.password_file.display()))?;
                let transport = AsyncSmtpTransport::<Tokio1Executor>::starttls_relay(&smtp.host)?
                    .port(smtp.port)
                    .credentials(Credentials::new(smtp.username.clone(), password.trim().to_owned()))
                    .build();
                Mailer::Smtp { transport: Box::new(transport), from: cfg.from.parse().context("[mail] from is not an email address")? }
            }
        })
    }

    pub fn enabled(&self) -> bool {
        !matches!(self, Mailer::None)
    }

    /// Email `code` to `to`.
    pub async fn send_code(&self, to: &str, purpose: CodePurpose, code: &str) -> anyhow::Result<()> {
        let (subject, body) = match purpose {
            CodePurpose::SignUp => (
                format!("{code} is your TeamTalk NG code"),
                format!(
                    "Your code to finish making your NG Account is:\n\n    {code}\n\nType it into TeamTalk NG. It works for 15 minutes.\n\nIf you didn't try to make an NG Account, you can ignore this email.\n"
                ),
            ),
            CodePurpose::Reset => (
                format!("{code} is your TeamTalk NG password reset code"),
                format!(
                    "Your code to choose a new NG Account password is:\n\n    {code}\n\nType it into TeamTalk NG. It works for 15 minutes.\n\nIf you didn't ask to reset your password, you can ignore this email; your password hasn't changed.\n"
                ),
            ),
        };
        match self {
            Mailer::None => bail!("Email is not set up on this monitor"),
            Mailer::Outbox { dir } => {
                let name = format!("{}-{}-{}.json", crate::store::now_ms(), purpose.as_str(), rand::random::<u32>());
                let mail = serde_json::json!({ "to": to, "purpose": purpose.as_str(), "code": code, "subject": subject, "body": body });
                std::fs::write(dir.join(name), serde_json::to_vec_pretty(&mail)?)?;
                Ok(())
            }
            Mailer::Smtp { transport, from } => {
                let message = Message::builder()
                    .from(from.clone())
                    .to(to.parse().context("That is not an email address")?)
                    .subject(subject)
                    .body(body)?;
                transport.send(message).await.context("The email could not be sent")?;
                Ok(())
            }
        }
    }
}
