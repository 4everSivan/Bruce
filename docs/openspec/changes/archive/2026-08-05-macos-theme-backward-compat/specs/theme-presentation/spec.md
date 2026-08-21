## ADDED Requirements

### Requirement: Interface style has classic and liquid glass modes

The system SHALL persist and expose an interface style preference with exactly two user-facing modes: classic and liquid glass. The system MUST NOT require liquid glass APIs to render the classic mode.

#### Scenario: Default on glass-capable system

- **WHEN** the user has no stored interface style and the runtime reports liquid glass as supported
- **THEN** the resolved interface style MUST be liquid glass

#### Scenario: Default on non-capable system

- **WHEN** the user has no stored interface style and the runtime reports liquid glass as unsupported
- **THEN** the resolved interface style MUST be classic

#### Scenario: Unsupported system ignores stored liquid glass

- **WHEN** stored interface style is liquid glass and the runtime reports liquid glass as unsupported
- **THEN** the resolved interface style MUST be classic and the app MUST continue without trapping

### Requirement: Liquid glass unavailable UI on unsupported systems

On systems where liquid glass is unsupported, the settings UI MUST show the liquid glass option in a disabled (grayed-out) state and MUST NOT allow selecting it. The UI SHOULD present a short explanation that macOS 26 or later is required.

#### Scenario: User cannot enable liquid glass below macOS 26

- **WHEN** liquid glass is unsupported and the user views the interface style control
- **THEN** the liquid glass option MUST be disabled and the active selection MUST remain classic

#### Scenario: Attempted programmatic set is rejected on unsupported systems

- **WHEN** liquid glass is unsupported and code requests setting interface style to liquid glass
- **THEN** the stored or resolved style MUST remain classic (fail-closed)

### Requirement: Blur style options only when liquid glass is active

Blur style options (standard / clear / matte corresponding to existing glass style values regular / clear / material) MUST be shown only when the resolved interface style is liquid glass and liquid glass is supported. When classic is active, blur style controls MUST be hidden.

#### Scenario: Blur picker visible under liquid glass on macOS 26+

- **WHEN** liquid glass is supported and the user selects liquid glass
- **THEN** the blur style control MUST be visible and MUST offer standard, clear, and matte choices

#### Scenario: Blur picker hidden under classic

- **WHEN** the resolved interface style is classic
- **THEN** the blur style control MUST NOT be visible

#### Scenario: Blur picker hidden when liquid glass unsupported

- **WHEN** liquid glass is unsupported
- **THEN** the blur style control MUST NOT be visible even if stored glass style is non-nil

### Requirement: Classic rendering path avoids liquid glass APIs

When the resolved interface style is classic, panel chrome, card backgrounds, and settings row chrome MUST render using classic materials or solid fills and MUST NOT invoke liquid glass effect APIs.

#### Scenario: Classic panel background

- **WHEN** resolved interface style is classic
- **THEN** the menu bar panel background MUST use a non-glass material or solid fill path

#### Scenario: Liquid glass panel background on capable systems

- **WHEN** resolved interface style is liquid glass and liquid glass is supported
- **THEN** the panel and cards MUST apply the selected blur style (standard / clear use glass effects; matte uses the existing material fallback)

### Requirement: Configuration compatibility with legacy glassStyle

The system MUST decode configurations that only contain the legacy `glassStyle` field. On glass-capable systems such configs MUST resolve to liquid glass with the stored blur style (or regular if missing). On unsupported systems they MUST resolve to classic without deleting the stored `glassStyle` value solely due to read-back.

#### Scenario: Legacy config on macOS 26+

- **WHEN** config JSON has `glassStyle` of `clear` and no `interfaceStyle`
- **THEN** resolved interface style MUST be liquid glass and resolved blur style MUST be clear

#### Scenario: Legacy config on older macOS

- **WHEN** config JSON has `glassStyle` of `clear` and no `interfaceStyle` and liquid glass is unsupported
- **THEN** resolved interface style MUST be classic and the app MUST still decode successfully

#### Scenario: Round-trip interface style

- **WHEN** the user sets interface style to classic and blur style was previously clear
- **THEN** after save and load the interface style MUST remain classic and the stored blur style MAY remain clear for future use on glass-capable systems

### Requirement: Capability probe is injectable for tests

The system MUST provide a pure resolution function (or equivalent) that maps stored preferences plus a boolean liquid-glass-supported flag to resolved theme values, so harnesses can test without changing the host OS version.

#### Scenario: Injected unsupported flag forces classic

- **WHEN** resolution is invoked with stored liquid glass and `isSupported == false`
- **THEN** the resolved interface style MUST be classic

#### Scenario: Injected supported flag honors liquid glass

- **WHEN** resolution is invoked with stored liquid glass and `isSupported == true`
- **THEN** the resolved interface style MUST be liquid glass
