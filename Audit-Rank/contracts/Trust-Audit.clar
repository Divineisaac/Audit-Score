;; Audit reputation system Smart Contract
;; This smart contract implements a comprehensive audit reputation ecosystem that enables:
;; 1. Management of qualified auditors with verification and removal capabilities
;; 2. Reputation token issuance, transfer, and burning with proper access controls
;; 3. Reputation decay mechanism to ensure ongoing quality maintenance
;; 4. Staking mechanism with time-locked positions and rewards
;; 5. Detailed audit submission, scoring, and statistical tracking
;; 6. Role-based permissions and whitelist functionality

;; Constants - Error codes
(define-constant ERR-UNAUTHORIZED-ACCESS (err u101))
(define-constant ERR-ALREADY-REGISTERED-AUDITOR (err u102))
(define-constant ERR-AUDITOR-CAPACITY-REACHED (err u103))
(define-constant ERR-EXCEEDS-MINT-LIMIT (err u104))
(define-constant ERR-AMOUNT-MUST-BE-POSITIVE (err u105))
(define-constant ERR-BALANCE-TOO-LOW (err u106))
(define-constant ERR-MAX-SUPPLY-EXCEEDED (err u107))
(define-constant ERR-SELF-TRANSFER-DISALLOWED (err u108))
(define-constant ERR-INSUFFICIENT-DECAY-PERIOD (err u109))
(define-constant ERR-SCORE-OUT-OF-RANGE (err u110))
(define-constant ERR-INVALID-AUDIT-DATA (err u111))
(define-constant ERR-AUDIT-NOT-FOUND (err u112))

;; Constants - System parameters
(define-constant contract-administrator tx-sender)
(define-constant maximum-auditor-slots u100)
(define-constant maximum-token-mint-amount u1000)
(define-constant total-token-supply-limit u1000000000)
(define-constant reputation-decay-percentage u10) ;; 10% decay per period
(define-constant reputation-decay-interval u52560) ;; Approximately 1 year in blocks (assuming 10-minute block time)
(define-constant minimum-quality-score u0)
(define-constant maximum-quality-score u100)

;; Token definition
(define-fungible-token auditor-reputation-token total-token-supply-limit)

;; Data variables
(define-data-var token-display-name (string-ascii 32) "Auditor Reputation Token")
(define-data-var token-ticker-symbol (string-ascii 10) "AREP")
(define-data-var token-decimal-places uint u6)
(define-data-var token-metadata-uri (optional (string-utf8 256)) none)
(define-data-var registered-auditor-count uint u0)
(define-data-var last-reputation-decay-block uint u0)

;; Data maps
(define-map verified-auditors principal bool)
(define-map approved-participants principal bool)
(define-map user-permissions principal (string-ascii 10))
(define-map last-reputation-update principal uint)
(define-map audit-submissions
    { audit-id: uint, auditor: principal }
    { quality-score: uint, submission-time: uint, audit-status: (string-ascii 20) })
(define-map auditor-performance-metrics principal 
    { completed-audits: uint, 
      quality-score-average: uint,
      reputation-bonus-multiplier: uint })
(define-map token-staking-records
    principal
    { staked-amount: uint, unlock-block-height: uint })

;; Private helper functions
(define-private (safe-addition (first-value uint) (second-value uint))
  (if (<= (+ first-value second-value) u18446744073709551615)
    (ok (+ first-value second-value))
    (err u100)))

(define-private (safe-subtraction (minuend uint) (subtrahend uint))
  (if (>= minuend subtrahend)
    (ok (- minuend subtrahend))
    (err u101)))

(define-private (calculate-decayed-reputation (current-balance uint) (last-update-block uint))
  (let
    (
      (current-block-height block-height)
      (decay-periods-elapsed (/ (- current-block-height last-update-block) reputation-decay-interval))
      (remaining-percentage-factor (pow (- u100 reputation-decay-percentage) decay-periods-elapsed))
    )
    (/ (* current-balance remaining-percentage-factor) (pow u100 decay-periods-elapsed))
  )
)

(define-private (calculate-audit-quality (completeness-score uint) (accuracy-score uint) (timeliness-score uint))
    (/ (+ completeness-score (* accuracy-score u2) timeliness-score) u4))

(define-private (update-auditor-metrics (auditor principal) (new-quality-score uint))
    (let
        ((existing-metrics (default-to
            { completed-audits: u0,
              quality-score-average: u0,
              reputation-bonus-multiplier: u100 }
            (map-get? auditor-performance-metrics auditor)))
         (updated-audit-count (+ (get completed-audits existing-metrics) u1))
         (updated-average-score (/ (+ (* (get quality-score-average existing-metrics)
                              (get completed-audits existing-metrics))
                           new-quality-score)
                        updated-audit-count)))
        (map-set auditor-performance-metrics
            auditor
            { completed-audits: updated-audit-count,
              quality-score-average: updated-average-score,
              reputation-bonus-multiplier: (determine-reputation-multiplier updated-average-score) })))

(define-private (determine-reputation-multiplier (average-quality-score uint))
    (if (>= average-quality-score u90)
        u150  ;; 1.5x multiplier for excellent performance
        (if (>= average-quality-score u80)
            u125  ;; 1.25x multiplier for good performance
            u100))) ;; 1x multiplier for standard performance

;; Token transfer functions
(define-public (transfer-reputation (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34))))
  (begin
    (asserts! (is-eq tx-sender sender) ERR-UNAUTHORIZED-ACCESS)
    (asserts! (> amount u0) ERR-AMOUNT-MUST-BE-POSITIVE)
    (asserts! (<= amount (ft-get-balance auditor-reputation-token sender)) ERR-BALANCE-TOO-LOW)
    (asserts! (not (is-eq sender recipient)) ERR-SELF-TRANSFER-DISALLOWED)
    (match (ft-transfer? auditor-reputation-token amount sender recipient)
      success (begin
        (print memo)
        (map-set last-reputation-update recipient block-height)
        (ok true))
      error (err u3))))

(define-public (burn-reputation (amount uint) (token-owner principal))
  (begin
    (asserts! (is-eq tx-sender token-owner) ERR-UNAUTHORIZED-ACCESS)
    (asserts! (> amount u0) ERR-AMOUNT-MUST-BE-POSITIVE)
    (asserts! (<= amount (ft-get-balance auditor-reputation-token token-owner)) ERR-BALANCE-TOO-LOW)
    (ft-burn? auditor-reputation-token amount token-owner)))

;; Auditor management functions
(define-public (register-auditor (new-auditor principal))
  (begin
    (asserts! (is-eq tx-sender contract-administrator) ERR-UNAUTHORIZED-ACCESS)
    (asserts! (is-none (map-get? verified-auditors new-auditor)) ERR-ALREADY-REGISTERED-AUDITOR)
    (asserts! (< (var-get registered-auditor-count) maximum-auditor-slots) ERR-AUDITOR-CAPACITY-REACHED)
    (map-set verified-auditors new-auditor true)
    (var-set registered-auditor-count (+ (var-get registered-auditor-count) u1))
    (print {event: "auditor_registered", auditor: new-auditor})
    (ok true)))

(define-public (deregister-auditor (auditor-to-remove principal))
  (begin
    (asserts! (is-eq tx-sender contract-administrator) ERR-UNAUTHORIZED-ACCESS)
    (asserts! (is-some (map-get? verified-auditors auditor-to-remove)) ERR-ALREADY-REGISTERED-AUDITOR)
    (map-delete verified-auditors auditor-to-remove)
    (var-set registered-auditor-count (- (var-get registered-auditor-count) u1))
    (ok true)))

(define-public (verify-auditor-status (auditor-to-check principal))
  (begin
    (asserts! (is-verified-auditor auditor-to-check) ERR-UNAUTHORIZED-ACCESS)
    (print {event: "auditor-status-verified", auditor: auditor-to-check})
    (ok true)))

;; Reputation decay function
(define-public (process-reputation-decay)
  (let
    (
      (current-block-height block-height)
      (previous-decay-block (var-get last-reputation-decay-block))
    )
    (if (>= (- current-block-height previous-decay-block) reputation-decay-interval)
      (begin
        (var-set last-reputation-decay-block current-block-height)
        (ok true))
      (err u109)) ;; Error: Not enough time has passed for decay
  )
)

;; Staking functions
(define-public (stake-reputation-tokens (amount uint) (lock-period uint))
    (let
        ((staker tx-sender)
         (current-block block-height)
         (unlock-block (+ current-block lock-period)))
        (begin
            (asserts! (> amount u0) ERR-AMOUNT-MUST-BE-POSITIVE)
            (asserts! (<= amount (ft-get-balance auditor-reputation-token staker)) ERR-BALANCE-TOO-LOW)
            (try! (ft-transfer? auditor-reputation-token amount staker (as-contract tx-sender)))
            (map-set token-staking-records staker
                { staked-amount: amount,
                  unlock-block-height: unlock-block })
            (print {event: "tokens_staked", staker: staker, amount: amount, unlock-time: unlock-block})
            (ok true))))

(define-public (unstake-reputation-tokens)
    (let
        ((staker tx-sender)
         (staking-position (unwrap! (map-get? token-staking-records staker) ERR-UNAUTHORIZED-ACCESS))
         (current-block block-height))
        (begin
            (asserts! (>= current-block (get unlock-block-height staking-position)) ERR-UNAUTHORIZED-ACCESS)
            (try! (as-contract (ft-transfer? auditor-reputation-token
                                           (get staked-amount staking-position)
                                           (as-contract tx-sender)
                                           staker)))
            (map-delete token-staking-records staker)
            (print {event: "tokens_unstaked", staker: staker, amount: (get staked-amount staking-position)})
            (ok true))))

;; Audit submission and reporting
(define-public (submit-audit-report 
    (audit-id uint)
    (completeness-rating uint)
    (accuracy-rating uint)
    (timeliness-rating uint)
    (audit-report-data (string-utf8 500)))
    (let
        ((submitting-auditor tx-sender)
         (final-quality-score (calculate-audit-quality completeness-rating accuracy-rating timeliness-rating)))
        (begin
            (asserts! (is-verified-auditor submitting-auditor) ERR-UNAUTHORIZED-ACCESS)
            (asserts! (and (>= final-quality-score minimum-quality-score) 
                          (<= final-quality-score maximum-quality-score)) 
                     ERR-SCORE-OUT-OF-RANGE)
            (map-set audit-submissions
                { audit-id: audit-id, auditor: submitting-auditor }
                { quality-score: final-quality-score,
                  submission-time: block-height,
                  audit-status: "completed" })
            (update-auditor-metrics submitting-auditor final-quality-score)
            (print {event: "audit_submitted",
                   auditor: submitting-auditor,
                   audit-id: audit-id,
                   score: final-quality-score})
            (ok true))))

;; Read-only functions
(define-read-only (get-decayed-reputation-balance (user principal))
  (let ((last-update-block (default-to u0 (map-get? last-reputation-update user))))
    (ok (calculate-decayed-reputation (ft-get-balance auditor-reputation-token user) last-update-block))))

(define-read-only (is-whitelisted-participant (user principal))
  (default-to false (map-get? approved-participants user)))

(define-read-only (is-verified-auditor (address principal))
  (default-to false (map-get? verified-auditors address)))

(define-read-only (get-token-name)
  (ok (var-get token-display-name)))

(define-read-only (get-token-symbol)
  (ok (var-get token-ticker-symbol)))

(define-read-only (get-token-decimals)
  (ok (var-get token-decimal-places)))

(define-read-only (get-token-balance (holder principal))
  (ok (ft-get-balance auditor-reputation-token holder)))

(define-read-only (get-total-token-supply)
  (ok (ft-get-supply auditor-reputation-token)))

(define-read-only (get-token-metadata-uri)
  (ok (var-get token-metadata-uri)))

(define-read-only (get-user-role (user principal))
  (default-to "user" (map-get? user-permissions user)))

(define-read-only (verify-supply-limit)
  (let ((current-supply (ft-get-supply auditor-reputation-token)))
    (if (> current-supply total-token-supply-limit)
      (err u107) ;; Error: Maximum token supply exceeded
      (ok true))))

(define-read-only (get-total-auditor-count)
  (ok (var-get registered-auditor-count)))

(define-public (get-contract-administrator)
  (ok contract-administrator))

(define-read-only (get-audit-submission (audit-id uint) (auditor principal))
    (map-get? audit-submissions { audit-id: audit-id, auditor: auditor }))

(define-read-only (get-auditor-performance (auditor principal))
    (map-get? auditor-performance-metrics auditor))

(define-read-only (get-staking-details (staker principal))
    (map-get? token-staking-records staker))

(define-read-only (calculate-staking-rewards (staker principal))
    (let
        ((staking-position (unwrap! (map-get? token-staking-records staker) (ok u0)))
         (locked-duration (- block-height (get unlock-block-height staking-position)))
         (base-annual-reward-rate u5)) ;; 5% base annual reward rate
        (ok (/ (* (get staked-amount staking-position) base-annual-reward-rate locked-duration)
               (* u100 reputation-decay-interval)))))