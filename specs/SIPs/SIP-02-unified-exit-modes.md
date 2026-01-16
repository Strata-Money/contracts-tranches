---
SIP: 02
Title: Unified Exit Modes
Author: Strata Protocol Contributors
Status: Final
Type: Protocol
Created: 2026-12-20
Requires: SIP-01
---

# SIP-02: Unified Exit Modes and Coverage-Aware Redemption Flow

## 1. Abstract

This specification defines a **unified exit-mode process** for Tranche Vault redemptions, formalizing three distinct exit modes:

1. **SharesLock**
2. **Fee**
3. **AssetsLock**

The SIP standardizes how exit modes are selected, how **coverage-dependent parameters** are applied, and how share-level and asset-level cooldowns interact during the withdrawal and redemption lifecycle.

---

## 2. Motivation

Historically, the protocol supported two exit behaviors:

* **Fee-based exits**, applying a static redemption fee
* **Asset-level cooldowns**, delaying asset delivery after shares were burned

With the introduction of **SharesLock**, the protocol gains the ability to:

* Delay redemptions *before* shares are burned
* Apply **dynamic, coverage-aware lock-ups and fees**
* Preserve ERC-4626 invariants while improving risk management

This SIP provides a single, coherent process model governing **all exit paths**, ensuring predictable behavior and extensibility.

---

## 3. Actors

* **User**: Initiates a `withdraw` or `redeem`
* **Tranche Vault**: An ERC-4626-compliant vault (Junior or Senior)
* **SharesCooldown Contract**: Calculates share lock-up duration and fees based on coverage
* **Strategy**: Underlying asset manager (may require unstaking)

---

## 4. Coverage Input

During every `withdraw` or `redeem` call, the Tranche Vault MUST compute the **current coverage ratio** and supply it to the SharesCooldown Contract.

Coverage is defined as:

```
Coverage = JuniorTVL / SeniorTVL
```

* Coverage is evaluated **at execution time**

---

## 5. Unified Exit Flow

### 5.1 SharesLock Exit Mode

When **SharesLock** is active:

1. The Vault passes the current coverage to the SharesCooldown Contract
2. The SharesCooldown Contract computes:

   * Share lock-up duration
   * Redemption fee (if configured)
3. If `cooldownSeconds > 0`:

   * Shares MUST NOT be burned
   * Shares are transferred to the SharesCooldown Contract
   * Lock-up metadata is recorded
4. If `cooldownSeconds == 0`:

   * Shares MAY be redeemed immediately
   * Fee logic is applied if configured

At this stage:

* No assets are transferred

---

### 5.2 Fee Exit Mode

When **SharesLock** is not active for a redemption, the protocol MAY select the **Fee** exit mode (as defined in earlier protocol versions) by checking global fee parameters configured in the CDO contract.

Under the Fee exit mode:

1. Shares are burned immediately
2. A redemption fee is accrued
3. The fee portion:

   * Either increases Junior or Senior TVL (retention), or
   * Is transferred to the protocol reserve
4. Net assets proceed to asset delivery

The fee applied in this mode is **not coverage-dependent**.

---

### 5.3 Fee Accrual Rules

Fee accrual MAY occur in the following scenarios:

* Immediate redemption under SharesLock when a fee is configured
* Fee-only exit mode

Fee application rules:

* Fees are expressed as a percentage of redeemed shares
* Fee logic MUST be applied **before asset transfer**

---

### 5.4 Asset Delivery and Asset Lock

After shares are burned and net assets are determined:

1. The Strategy is instructed to release assets
2. If an asset-level cooldown is enabled:

   * Assets are transferred into the ERC-20 AssetCooldown contract
3. Otherwise:

   * Assets are transferred directly to the receiver

Asset-level cooldowns are **independent of SharesLock** and MAY be applied in combination when configured.

---

### 5.5 Mandatory Unstaking

If the Strategy MUST return an unstaked asset (e.g., USDe):

1. The Strategy initiates the unstaking process
2. The protocol enforces the mandatory unstaking cooldown
3. Assets are transferred only after unstaking finalization

This process is orthogonal to both SharesLock and AssetsLock and MUST always be honored.

---

## 6. Backward Compatibility

* Existing Fee and AssetsLock flows remain valid
* SharesLock is opt-in via protocol configuration
* No changes are required for ERC-4626 integrators

---
