;; Business Permit Application Processing Contract
;; Streamlines applications for operating permits and licenses

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-INVALID-APPLICATION (err u201))
(define-constant ERR-APPLICATION-EXISTS (err u202))
(define-constant ERR-INSUFFICIENT-PAYMENT (err u203))
(define-constant ERR-INVALID-INPUT (err u204))
(define-constant ERR-INVALID-STATUS (err u205))

;; Data Variables
(define-data-var next-application-id uint u1)
(define-data-var contract-admin principal CONTRACT-OWNER)

;; Data Maps
(define-map applications
  { application-id: uint }
  {
    business-type: (string-ascii 50),
    business-name: (string-ascii 100),
    business-address: (string-ascii 200),
    applicant: principal,
    application-date: uint,
    status: (string-ascii 20),
    fee-amount: uint,
    fee-paid: bool,
    approval-date: uint,
    expiration-date: uint,
    reviewer: (optional principal),
    notes: (string-ascii 500)
  }
)

(define-map business-lookup
  { business-name: (string-ascii 100), business-address: (string-ascii 200) }
  { application-id: uint }
)

(define-map authorized-reviewers
  { reviewer: principal }
  { authorized: bool, department: (string-ascii 50) }
)

(define-map permit-requirements
  { business-type: (string-ascii 50) }
  {
    base-fee: uint,
    processing-days: uint,
    validity-period: uint,
    required-inspections: uint
  }
)

(define-map inspections
  { application-id: uint, inspection-type: (string-ascii 50) }
  {
    scheduled-date: uint,
    completed-date: uint,
    inspector: principal,
    result: (string-ascii 20),
    notes: (string-ascii 300)
  }
)

;; Authorization Functions
(define-private (is-contract-admin (user principal))
  (is-eq user (var-get contract-admin))
)

(define-private (is-authorized-reviewer (user principal))
  (default-to false (get authorized (map-get? authorized-reviewers { reviewer: user })))
)

;; Admin Functions
(define-public (set-contract-admin (new-admin principal))
  (begin
    (asserts! (is-contract-admin tx-sender) ERR-NOT-AUTHORIZED)
    (var-set contract-admin new-admin)
    (ok true)
  )
)

(define-public (add-authorized-reviewer (reviewer principal) (department (string-ascii 50)))
  (begin
    (asserts! (is-contract-admin tx-sender) ERR-NOT-AUTHORIZED)
    (map-set authorized-reviewers
      { reviewer: reviewer }
      { authorized: true, department: department }
    )
    (ok true)
  )
)

(define-public (set-permit-requirements
  (business-type (string-ascii 50))
  (base-fee uint)
  (processing-days uint)
  (validity-period uint)
  (required-inspections uint)
)
  (begin
    (asserts! (is-contract-admin tx-sender) ERR-NOT-AUTHORIZED)
    (map-set permit-requirements
      { business-type: business-type }
      {
        base-fee: base-fee,
        processing-days: processing-days,
        validity-period: validity-period,
        required-inspections: required-inspections
      }
    )
    (ok true)
  )
)

;; Core Application Functions
(define-public (submit-application
  (business-type (string-ascii 50))
  (business-name (string-ascii 100))
  (business-address (string-ascii 200))
  (fee-amount uint)
)
  (let
    (
      (application-id (var-get next-application-id))
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
      (requirements (map-get? permit-requirements { business-type: business-type }))
    )
    (asserts! (> (len business-type) u0) ERR-INVALID-INPUT)
    (asserts! (> (len business-name) u0) ERR-INVALID-INPUT)
    (asserts! (> (len business-address) u0) ERR-INVALID-INPUT)
    (asserts! (is-none (map-get? business-lookup { business-name: business-name, business-address: business-address })) ERR-APPLICATION-EXISTS)

    ;; Check fee amount if requirements exist
    (match requirements
      req-data (asserts! (>= fee-amount (get base-fee req-data)) ERR-INSUFFICIENT-PAYMENT)
      true ;; No requirements set, accept any fee
    )

    (map-set applications
      { application-id: application-id }
      {
        business-type: business-type,
        business-name: business-name,
        business-address: business-address,
        applicant: tx-sender,
        application-date: current-time,
        status: "submitted",
        fee-amount: fee-amount,
        fee-paid: false,
        approval-date: u0,
        expiration-date: u0,
        reviewer: none,
        notes: ""
      }
    )

    (map-set business-lookup
      { business-name: business-name, business-address: business-address }
      { application-id: application-id }
    )

    (var-set next-application-id (+ application-id u1))
    (ok application-id)
  )
)

(define-public (pay-application-fee (application-id uint))
  (let
    (
      (app-data (unwrap! (map-get? applications { application-id: application-id }) ERR-INVALID-APPLICATION))
    )
    (asserts! (is-eq (get applicant app-data) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (not (get fee-paid app-data)) ERR-INVALID-STATUS)

    ;; In a real implementation, this would handle STX transfer
    ;; For now, we just mark as paid
    (map-set applications
      { application-id: application-id }
      (merge app-data { fee-paid: true, status: "under-review" })
    )
    (ok true)
  )
)

(define-public (review-application (application-id uint) (decision (string-ascii 20)) (notes (string-ascii 500)))
  (let
    (
      (app-data (unwrap! (map-get? applications { application-id: application-id }) ERR-INVALID-APPLICATION))
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
      (requirements (map-get? permit-requirements { business-type: (get business-type app-data) }))
    )
    (asserts! (is-authorized-reviewer tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (get fee-paid app-data) ERR-INVALID-STATUS)
    (asserts! (or (is-eq decision "approved") (is-eq decision "rejected") (is-eq decision "pending")) ERR-INVALID-INPUT)

    (let
      (
        (expiration-date
          (if (is-eq decision "approved")
            (match requirements
              req-data (+ current-time (get validity-period req-data))
              (+ current-time u31536000) ;; Default 1 year
            )
            u0
          )
        )
        (approval-date (if (is-eq decision "approved") current-time u0))
      )
      (map-set applications
        { application-id: application-id }
        (merge app-data {
          status: decision,
          reviewer: (some tx-sender),
          notes: notes,
          approval-date: approval-date,
          expiration-date: expiration-date
        })
      )
      (ok true)
    )
  )
)

(define-public (schedule-inspection
  (application-id uint)
  (inspection-type (string-ascii 50))
  (scheduled-date uint)
)
  (let
    (
      (app-data (unwrap! (map-get? applications { application-id: application-id }) ERR-INVALID-APPLICATION))
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    (asserts! (is-authorized-reviewer tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status app-data) "approved") ERR-INVALID-STATUS)
    (asserts! (> scheduled-date current-time) ERR-INVALID-INPUT)

    (map-set inspections
      { application-id: application-id, inspection-type: inspection-type }
      {
        scheduled-date: scheduled-date,
        completed-date: u0,
        inspector: tx-sender,
        result: "scheduled",
        notes: ""
      }
    )
    (ok true)
  )
)

(define-public (complete-inspection
  (application-id uint)
  (inspection-type (string-ascii 50))
  (result (string-ascii 20))
  (notes (string-ascii 300))
)
  (let
    (
      (inspection-data (unwrap! (map-get? inspections { application-id: application-id, inspection-type: inspection-type }) ERR-INVALID-APPLICATION))
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    (asserts! (is-authorized-reviewer tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get result inspection-data) "scheduled") ERR-INVALID-STATUS)
    (asserts! (or (is-eq result "passed") (is-eq result "failed")) ERR-INVALID-INPUT)

    (map-set inspections
      { application-id: application-id, inspection-type: inspection-type }
      (merge inspection-data {
        completed-date: current-time,
        result: result,
        notes: notes
      })
    )
    (ok true)
  )
)

;; Read-Only Functions
(define-read-only (get-application-status (application-id uint))
  (map-get? applications { application-id: application-id })
)

(define-read-only (get-application-by-business (business-name (string-ascii 100)) (business-address (string-ascii 200)))
  (let
    (
      (lookup-result (map-get? business-lookup { business-name: business-name, business-address: business-address }))
    )
    (match lookup-result
      lookup-data (map-get? applications { application-id: (get application-id lookup-data) })
      none
    )
  )
)

(define-read-only (get-permit-requirements-for-type (business-type (string-ascii 50)))
  (map-get? permit-requirements { business-type: business-type })
)

(define-read-only (get-inspection-status (application-id uint) (inspection-type (string-ascii 50)))
  (map-get? inspections { application-id: application-id, inspection-type: inspection-type })
)

(define-read-only (is-permit-valid (application-id uint))
  (let
    (
      (app-data (map-get? applications { application-id: application-id }))
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    (match app-data
      application
        (and
          (is-eq (get status application) "approved")
          (> (get expiration-date application) current-time)
        )
      false
    )
  )
)
