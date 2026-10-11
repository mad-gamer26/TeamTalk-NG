//! One line of TeamTalk's text protocol (the TCP side every client speaks):
//!
//! ```text
//! messagedeliver type=1 srcuserid=12 destuserid=7 content="Hi\nthere" more=0
//! ```
//!
//! A line is a command or event name followed by `name=value` parameters.
//! A value is an integer, a quoted string (with `\\`, `\"`, `\n` and `\r`
//! escaped) or a list of integers in square brackets.

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    Int(i64),
    Str(String),
    List(Vec<i64>),
}

impl From<i64> for Value {
    fn from(v: i64) -> Self {
        Value::Int(v)
    }
}

impl From<i32> for Value {
    fn from(v: i32) -> Self {
        Value::Int(v.into())
    }
}

impl From<&str> for Value {
    fn from(v: &str) -> Self {
        Value::Str(v.to_owned())
    }
}

impl From<String> for Value {
    fn from(v: String) -> Self {
        Value::Str(v)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Line {
    pub name: String,
    /// Parameters in the order they were given (the order matters only for
    /// readability; servers accept any order).
    pub params: Vec<(String, Value)>,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
#[error("unreadable TeamTalk line: {0}")]
pub struct ParseError(pub String);

impl Value {
    /// As JSON: a number, a string, or a list of numbers.
    pub fn to_json(&self) -> serde_json::Value {
        match self {
            Value::Int(i) => (*i).into(),
            Value::Str(s) => s.clone().into(),
            Value::List(l) => l.clone().into(),
        }
    }

    /// From JSON, for values the app sends; other shapes are refused.
    pub fn from_json(v: &serde_json::Value) -> Option<Value> {
        match v {
            serde_json::Value::Number(n) => n.as_i64().map(Value::Int),
            serde_json::Value::String(s) => Some(Value::Str(s.clone())),
            serde_json::Value::Bool(b) => Some(Value::Int(i64::from(*b))),
            serde_json::Value::Array(a) => a.iter().map(|x| x.as_i64()).collect::<Option<Vec<_>>>().map(Value::List),
            _ => None,
        }
    }
}

impl Line {
    /// The parameters as a JSON object, with the line's name as `type`.
    pub fn to_json(&self) -> serde_json::Value {
        let mut map = serde_json::Map::new();
        map.insert("type".into(), self.name.clone().into());
        for (k, v) in &self.params {
            map.insert(k.clone(), v.to_json());
        }
        serde_json::Value::Object(map)
    }

    pub fn new(name: &str) -> Self {
        Line { name: name.to_owned(), params: Vec::new() }
    }

    pub fn with(mut self, key: &str, value: impl Into<Value>) -> Self {
        self.set(key, value);
        self
    }

    pub fn set(&mut self, key: &str, value: impl Into<Value>) {
        let value = value.into();
        match self.params.iter_mut().find(|(k, _)| k == key) {
            Some((_, v)) => *v = value,
            None => self.params.push((key.to_owned(), value)),
        }
    }

    pub fn get(&self, key: &str) -> Option<&Value> {
        self.params.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }

    pub fn has(&self, key: &str) -> bool {
        self.get(key).is_some()
    }

    /// An integer parameter. Servers always send numbers unquoted, but a
    /// quoted number is accepted too.
    pub fn int(&self, key: &str) -> Option<i64> {
        match self.get(key)? {
            Value::Int(v) => Some(*v),
            Value::Str(s) => s.parse().ok(),
            Value::List(_) => None,
        }
    }

    pub fn str(&self, key: &str) -> Option<&str> {
        match self.get(key)? {
            Value::Str(s) => Some(s),
            _ => None,
        }
    }

    /// A string parameter, or an empty string when it is missing.
    pub fn text(&self, key: &str) -> String {
        match self.get(key) {
            Some(Value::Str(s)) => s.clone(),
            Some(Value::Int(v)) => v.to_string(),
            _ => String::new(),
        }
    }

    pub fn list(&self, key: &str) -> Option<&[i64]> {
        match self.get(key)? {
            Value::List(v) => Some(v),
            _ => None,
        }
    }

    pub fn parse(text: &str) -> Result<Line, ParseError> {
        let text = text.trim_end_matches(['\r', '\n']);
        let mut p = Parser { s: text, pos: 0 };
        p.skip_space();
        let name = p.ident().ok_or_else(|| ParseError(text.to_owned()))?;
        let mut line = Line::new(name);
        loop {
            p.skip_space();
            if p.done() {
                break;
            }
            let key = p.ident().ok_or_else(|| ParseError(text.to_owned()))?;
            if !p.eat('=') {
                // A bare word: TeamTalk never sends one, but keep it rather
                // than failing the whole line.
                line.params.push((key.to_owned(), Value::Str(String::new())));
                continue;
            }
            let value = p.value().ok_or_else(|| ParseError(text.to_owned()))?;
            line.params.push((key.to_owned(), value));
        }
        Ok(line)
    }
}

impl fmt::Display for Line {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.name)?;
        for (k, v) in &self.params {
            write!(f, " {k}=")?;
            match v {
                Value::Int(i) => write!(f, "{i}")?,
                Value::Str(s) => {
                    f.write_str("\"")?;
                    for c in s.chars() {
                        match c {
                            '\\' => f.write_str("\\\\")?,
                            '"' => f.write_str("\\\"")?,
                            '\n' => f.write_str("\\n")?,
                            '\r' => f.write_str("\\r")?,
                            c => write!(f, "{c}")?,
                        }
                    }
                    f.write_str("\"")?;
                }
                Value::List(items) => {
                    f.write_str("[")?;
                    for (i, item) in items.iter().enumerate() {
                        if i > 0 {
                            f.write_str(",")?;
                        }
                        write!(f, "{item}")?;
                    }
                    f.write_str("]")?;
                }
            }
        }
        Ok(())
    }
}

struct Parser<'a> {
    s: &'a str,
    pos: usize,
}

impl<'a> Parser<'a> {
    fn rest(&self) -> &'a str {
        &self.s[self.pos..]
    }

    fn done(&self) -> bool {
        self.pos >= self.s.len()
    }

    fn peek(&self) -> Option<char> {
        self.rest().chars().next()
    }

    fn eat(&mut self, c: char) -> bool {
        if self.peek() == Some(c) {
            self.pos += c.len_utf8();
            true
        } else {
            false
        }
    }

    fn skip_space(&mut self) {
        while matches!(self.peek(), Some(' ' | '\t')) {
            self.pos += 1;
        }
    }

    fn ident(&mut self) -> Option<&'a str> {
        let rest = self.rest();
        let len = rest
            .char_indices()
            .find(|(i, c)| {
                !(c.is_ascii_alphabetic() || *c == '_' || (*i > 0 && (c.is_ascii_digit() || *c == '-')))
            })
            .map(|(i, _)| i)
            .unwrap_or(rest.len());
        if len == 0 {
            return None;
        }
        self.pos += len;
        Some(&rest[..len])
    }

    fn value(&mut self) -> Option<Value> {
        match self.peek() {
            Some('"') => {
                self.pos += 1;
                let mut out = String::new();
                let mut chars = self.rest().char_indices();
                while let Some((i, c)) = chars.next() {
                    match c {
                        '"' => {
                            self.pos += i + 1;
                            return Some(Value::Str(out));
                        }
                        '\\' => match chars.next() {
                            Some((_, 'n')) => out.push('\n'),
                            Some((_, 'r')) => out.push('\r'),
                            Some((_, other)) => out.push(other),
                            None => return None,
                        },
                        c => out.push(c),
                    }
                }
                None
            }
            Some('[') => {
                let end = self.rest().find(']')?;
                let inner = &self.rest()[1..end];
                self.pos += end + 1;
                let items = inner
                    .split(',')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(|s| s.parse().ok())
                    .collect::<Option<Vec<i64>>>()?;
                Some(Value::List(items))
            }
            Some(_) => {
                let rest = self.rest();
                let len = rest.find([' ', '\t']).unwrap_or(rest.len());
                let word = &rest[..len];
                self.pos += len;
                Some(match word.parse() {
                    Ok(i) => Value::Int(i),
                    Err(_) => Value::Str(word.to_owned()),
                })
            }
            None => Some(Value::Str(String::new())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_welcome() {
        let l = Line::parse("teamtalk userid=2 maxusers=1000 maxiplogins=0 usertimeout=60 protocol=\"5.14\"\r\n").unwrap();
        assert_eq!(l.name, "teamtalk");
        assert_eq!(l.int("userid"), Some(2));
        assert_eq!(l.int("usertimeout"), Some(60));
        assert_eq!(l.str("protocol"), Some("5.14"));
    }

    #[test]
    fn parses_escapes_and_lists() {
        let l = Line::parse(r#"messagedeliver type=1 content="say \"hi\"\nback\\slash ünï" ops=[1,2, 3] empty=[]"#).unwrap();
        assert_eq!(l.text("content"), "say \"hi\"\nback\\slash ünï");
        assert_eq!(l.list("ops"), Some(&[1, 2, 3][..]));
        assert_eq!(l.list("empty"), Some(&[][..]));
    }

    #[test]
    fn negative_numbers_and_unquoted_words() {
        let l = Line::parse("updateuser userid=5 volume=-3 x=abc").unwrap();
        assert_eq!(l.int("volume"), Some(-3));
        assert_eq!(l.str("x"), Some("abc"));
    }

    #[test]
    fn round_trips() {
        let l = Line::new("message")
            .with("type", 1)
            .with("destuserid", 9)
            .with("content", "line one\r\nline \"two\" \\ end")
            .with("list", Value::List(vec![4, 5]));
        let text = l.to_string();
        assert_eq!(text, r#"message type=1 destuserid=9 content="line one\r\nline \"two\" \\ end" list=[4,5]"#);
        assert_eq!(Line::parse(&text).unwrap(), l);
    }

    #[test]
    fn rejects_garbage() {
        assert!(Line::parse("").is_err());
        assert!(Line::parse("x content=\"unterminated").is_err());
    }
}
