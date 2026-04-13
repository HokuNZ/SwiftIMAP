# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-04-13

### Added
- Initial release
- IMAP protocol parser and encoder
- Networking layer with TLS support (SwiftNIO + NIOSSL)
- Authentication methods: LOGIN, PLAIN, OAuth2, External, custom SASL
- Core commands: CAPABILITY, LIST, SELECT, FETCH, SEARCH, STORE
- High-level async/await client API
- Command-line testing tool
- Comprehensive unit test coverage
