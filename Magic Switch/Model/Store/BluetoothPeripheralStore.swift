import Foundation
import IOBluetooth
import SwiftUI

/// Protocol defining the interface for Bluetooth peripheral management operations
protocol BluetoothPeripheralManageable {
  /// Fetches and updates the list of connected peripherals
  func fetchConnectedPeripherals()

  /// Adds a new peripheral to the managed list
  func addPeripheral(_ peripheral: BluetoothPeripheral)

  /// Initiates connection to a peripheral
  func connectPeripheral(_ peripheral: BluetoothPeripheral)

  /// Releases a peripheral without changing its Bluetooth pairing
  func releasePeripheral(
    _ peripheral: BluetoothPeripheral,
    reclaimOnLeaseExpiry: Bool,
    completion: ((Bool) -> Void)?
  )
}

/// Manages the state and operations of Bluetooth peripherals
final class BluetoothPeripheralStore: NSObject, ObservableObject, BluetoothPeripheralManageable {
  // MARK: - Singleton

  static let shared = BluetoothPeripheralStore()

  // MARK: - Constants

  private enum Constants {
    static let queueLabel = "com.magicswitch.bluetooth"
    /// During a handoff, keep actively releasing any connection macOS restores
    /// on the source Mac. This gives the destination Mac a stable window in
    /// which to open its already-paired connection.
    static let handoffReleaseLease: TimeInterval = 30
    /// How long after wake to wait before deciding whether the peer holds a
    /// peripheral we released for sleep. Gives Wi-Fi time to reassociate so a
    /// peer that's actively using the peripheral doesn't look unreachable and
    /// get it yanked back.
    static let wakeReclaimDelay: TimeInterval = 5
    /// Upper bound on how long `prepareForSleep` blocks the (held) sleep
    /// transition waiting for the peer to ack the proactive handoff push (see
    /// `prepareForSleep`). A present peer acks in well under a second; the cap
    /// keeps a peer that vanished in the same instant from delaying sleep more
    /// than briefly. Stays well inside the OS's ~30s power-handler watchdog.
    static let sleepHandoffAckTimeout: TimeInterval = 3
    /// How often the auto-reconnect watcher retries a dropped peripheral.
    static let reconnectProbeInterval: TimeInterval = 5
    /// Timer leeway for the probe — kept small so the OS can coalesce the
    /// wakeup a little without materially delaying the catch.
    static let reconnectProbeLeeway: DispatchTimeInterval = .milliseconds(500)
    /// Upper bound on how long the watcher keeps trying to reclaim one
    /// peripheral before giving up. The recovery case is a user who notices a
    /// stuck peripheral and power-cycles it, so a few minutes covers it; an
    /// hour would just burn wakeups on a device that's genuinely gone (off, out
    /// of range, carried away). A fresh drop or wake re-arms it.
    static let reconnectMaxWindow: TimeInterval = 600
    /// Consecutive peer-absent `HOLDS_ONE` probes an *adoption* needs before
    /// it takes a peripheral. Two probes (one extra tick) give Wi-Fi that's
    /// still reassociating after wake a chance to come up — so a peer that's
    /// actually alive gets to answer and stand the adoption down — while
    /// keeping lid-open → peripheral-back under ~20s.
    static let adoptionRequiredAbsentStreak = 2
    /// Failed local connection attempts after which an adoption gives up.
    /// Repeated failures usually mean the device is still held by a peer we
    /// cannot reach, so bound the background retry churn.
    /// Reclaims — a prior claim — keep the full `reconnectMaxWindow` retry.
    static let adoptionMaxConnectAttempts = 3
  }

  /// Result of asking IOBluetooth to close an existing baseband connection.
  /// `closeConnection()` is synchronous and its success return is authoritative;
  /// an immediately-following `isConnected()` snapshot can still be stale or
  /// reflect a rapid macOS reconnect, so it must never overturn that result.
  private enum CloseConnectionOutcome {
    case released
    case failed(IOReturn)
  }

  // MARK: - Dependencies

  private let bluetoothQueue = DispatchQueue(label: Constants.queueLabel, qos: .userInitiated)

  /// Releases held peripherals just before this Mac sleeps. A sleeping Mac
  /// can't be asked to release over the network, so we hand them off *before*
  /// becoming unreachable.
  private let sleepMonitor = SleepMonitor()

  // MARK: - Properties

  /// `@AppStorage` key for the "release peripherals when this Mac sleeps"
  /// preference. Referenced by the Other settings tab's toggle too, so it
  /// lives here as the single source of truth for the key string.
  static let releaseOnSleepDefaultsKey = "releaseHeldPeripheralsOnSleep"

  /// `@AppStorage` key for the "keep trying to reconnect dropped peripherals"
  /// preference. Also bound by the Other settings tab, so the key string
  /// lives here as the single source of truth.
  static let autoReconnectDefaultsKey = "autoReconnectDroppedPeripherals"

  /// `@AppStorage` key for the per-peripheral icon/type overrides map.
  static let typeOverridesDefaultsKey = "peripheralTypeOverrides"

  /// `@AppStorage` key for the last-known Class of Device per address.
  static let deviceClassesDefaultsKey = "peripheralDeviceClasses"

  @AppStorage("peripherals") private var peripheralsData: Data = Data()

  @AppStorage(BluetoothPeripheralStore.typeOverridesDefaultsKey)
  private var typeOverridesData: Data = Data()

  @AppStorage(BluetoothPeripheralStore.deviceClassesDefaultsKey)
  private var deviceClassesData: Data = Data()

  /// When set (default), `prepareForSleep` releases held peripherals on
  /// system sleep. Off lets a user keep the active peripheral connection on a
  /// Mac that sleeps (the watcher still reclaims it on wake if it drops).
  @AppStorage(BluetoothPeripheralStore.releaseOnSleepDefaultsKey)
  private var releaseOnSleep: Bool = true

  /// When set (default), a peripheral that drops while it should be on this
  /// Mac is retried by the auto-reconnect watcher until it's back in range
  /// and the peer isn't using it, or the `reconnectMaxWindow` expires. Off
  /// disables the watcher entirely. Read at use-time (no observation needed):
  /// `armReconnect` refuses when off and `reconnectTick` tears itself down.
  @AppStorage(BluetoothPeripheralStore.autoReconnectDefaultsKey)
  private var autoReconnect: Bool = true

  @Published private(set) var peripherals: [BluetoothPeripheral] = [] {
    didSet {
      savePeripherals()
    }
  }

  @Published private(set) var discoveredPeripherals: [BluetoothPeripheral] = []

  /// User-chosen type per peripheral address, overriding auto-detection. Local
  /// to this Mac (not synced — the peer auto-detects its own icons). Persisted.
  @Published private(set) var typeOverrides: [String: PeripheralType] = [:] {
    didSet { saveTypeOverrides() }
  }

  /// Bluetooth Class of Device per address, captured from the live paired
  /// snapshot. Feeds auto-detection (especially audio gear, whose names rarely
  /// say "headphones"). Persisted and merged rather than replaced so a
  /// temporarily unavailable or manually unpaired device retains its last
  /// known icon classification. A device's class does not change for a given
  /// address, so kept entries stay correct.
  @Published private(set) var deviceClasses: [String: UInt32] = [:] {
    didSet { saveDeviceClasses() }
  }

  /// Runtime connection state per peripheral id. Driven by connection results
  /// and IOBluetooth disconnect notifications.
  @Published private(set) var connectionStates: [String: PeripheralConnectionState] = [:]

  /// Battery percentage per connected peripheral id, refreshed by each
  /// `fetchConnectedPeripherals` snapshot (the Peripheral tab polls that on
  /// a 2s timer). Published state rather than a read-at-render registry
  /// lookup because a just-connected device surfaces `BatteryPercent` a
  /// beat *after* its `.connected` state change — a view that reads the
  /// registry directly during that render never hears about the late value.
  @Published private(set) var batteryLevels: [String: Int] = [:]

  /// Inline per-peripheral error shown under the row in the menu-bar dropdown
  /// (so a failed switch is visible without relying on the system notification).
  /// Set on a switch failure; fades after 5s, or sooner when `setConnectionState`
  /// sees the next attempt (`.connecting`) or success (`.connected`).
  @Published private(set) var peripheralOperationError: [String: String] = [:]
  /// Per-peripheral fade timers for `peripheralOperationError`.
  private var peripheralErrorTimers: [String: DispatchSourceTimer] = [:]

  /// Disconnect notification observers, keyed by peripheral id.
  private var disconnectObservers: [String: IOBluetoothUserNotification] = [:]

  /// MAC addresses this app deliberately disconnected immediately before the
  /// last sleep. When auto-reconnect is off, wake performs one protected
  /// reconnect attempt for just this subset.
  private var peripheralsDisconnectedForSleep: Set<String> = []

  /// MAC addresses that were *connected to this Mac* immediately before the
  /// last sleep — a superset of `peripheralsDisconnectedForSleep`. On wake the
  /// watcher tries to reclaim any that didn't come back
  /// on their own, so "whatever I was using before I closed the lid" returns
  /// even when nothing was handed off. Only consulted when auto-reconnect is
  /// on.
  private var connectedBeforeSleep: Set<String> = []

  /// Global IOBluetooth connect observer. Fires for *any* device the OS
  /// connects, including ones the user connects via the system
  /// Bluetooth menu (not via Magic Switch). Used to keep the Peripheral tab
  /// live without polling.
  private var globalConnectObserver: IOBluetoothUserNotification?

  /// Peripherals the auto-reconnect watcher is trying to get onto this Mac,
  /// keyed by id, with the time each was armed (for the `reconnectMaxWindow`
  /// bound). An entry comes in one of two flavours: a *reclaim* (default —
  /// this Mac has a prior claim: a genuine drop, a failed handoff, or a held
  /// set being chased back after wake) or an *adoption* (no prior claim; see
  /// `adoptionProgress`). Main-only.
  private var reconnectWatchlist: [String: Date] = [:]

  /// Ids with a probe/reclaim chain in flight, so overlapping ticks don't
  /// fire a second `HOLDS_ONE` or connection attempt for the same peripheral while
  /// the first is still resolving. Main-only.
  private var reconnectInFlight: Set<String> = []

  /// Per-id bookkeeping for adoption arms; see `adoptionProgress`.
  private struct AdoptionProgress {
    /// Consecutive `HOLDS_ONE` probes that ended peer-absent (unreachable at
    /// the TCP/connect layer). Reset implicitly: any answered probe stands
    /// the adoption down instead.
    var peerAbsentStreak = 0
    /// Local connection attempts made for this adoption so far.
    var connectAttempts = 0
  }

  /// Watchlist entries armed as *adoption*: peripherals this Mac wasn't
  /// holding (they lived on the peer) whose peer has dropped off the network
  /// — slept, shut down, or left. Presence in this map is what distinguishes
  /// an adoption from a reclaim. Adoption is deliberately more polite: it
  /// takes a peripheral only from a *provably absent* peer (per
  /// `continueAdoption`), stands down the moment a live peer answers at all
  /// — "not holding" included, so a prior holder's reclaim or the user
  /// outranks it — and caps its connection attempts. Main-only.
  private var adoptionProgress: [String: AdoptionProgress] = [:]

  private struct ReleaseLease {
    let expiresAt: Date
    let reclaimOnExpiry: Bool
  }

  /// Per-device release leases. They suppress the app's reconnect watcher and
  /// make global connect notifications close any session macOS automatically
  /// restores on the source Mac. Main-only.
  private var releaseLeases: [String: ReleaseLease] = [:]
  private var releaseLeaseTimers: [String: DispatchSourceTimer] = [:]

  /// Self-rescheduling one-shot probe timer; runs only while
  /// `reconnectWatchlist` is non-empty, at `Constants.reconnectProbeInterval`.
  private var reconnectTimer: DispatchSourceTimer?

  /// Identity of the newest connect attempt per address. Everything above is
  /// keyed by address alone, and overlapping attempts for one address are
  /// reachable when a peer command starts a fresh attempt. Completion paths
  /// carry their attempt's token and no-op once stale, so an older synchronous
  /// `openConnection()` result cannot overwrite a newer intent. Main-only.
  private var connectAttemptTokens: [String: UInt64] = [:]
  /// Backing counter for `connectAttemptTokens`; lock-guarded so attempts
  /// can be minted from any thread.
  private var connectAttemptCounter: UInt64 = 0
  private let attemptTokenLock = NSLock()

  // MARK: - Computed Properties

  var availablePeripherals: [BluetoothPeripheral] {
    discoveredPeripherals.filter { discovered in
      !peripherals.contains(where: { $0.id == discovered.id })
    }
  }

  func connectionState(for peripheralID: String) -> PeripheralConnectionState {
    connectionStates[peripheralID] ?? .disconnected
  }

  /// True while any registered peripheral is mid-transition (`.connecting` or
  /// `.releasing`). The full-set switch is blocked while this holds so it can't
  /// issue a re-entrant connect/release on a peripheral that's already connecting
  /// or being handed off. Reads `connectionStates`; main-thread only.
  var isAnyPeripheralTransitioning: Bool {
    peripherals.contains { peripheral in
      let state = connectionState(for: peripheral.id)
      return state == .connecting || state == .releasing
    }
  }

  enum PeripheralPresence {
    case none
    case connectedHere
    case away
  }

  /// Whether any registered peripheral is on this Mac, none are, or the
  /// answer isn't known. `.releasing` counts as here: the device stays
  /// physically connected through the handoff preflight, and the transfer
  /// arrow takes over the icon once the release actually starts. Reads
  /// `connectionStates`; main-thread only.
  var peripheralPresence: PeripheralPresence {
    Self.presence(of: peripherals, connectionStates: connectionStates)
  }

  /// A registered peripheral with no `connectionStates` entry hasn't been
  /// resolved by a snapshot yet (every snapshot writes one per registered
  /// id), so its absence means "unknown", not "away".
  static func presence(
    of peripherals: [BluetoothPeripheral],
    connectionStates: [String: PeripheralConnectionState]
  ) -> PeripheralPresence {
    guard !peripherals.isEmpty else { return .none }
    var unresolved = false
    for peripheral in peripherals {
      switch connectionStates[peripheral.id] {
      case .connected, .releasing: return .connectedHere
      case .disconnected, .connecting: break
      case nil: unresolved = true
      }
    }
    return unresolved ? .none : .away
  }

  /// Resolved display type for `peripheral`: the user's manual override if set,
  /// otherwise auto-detected from the name and (when known) its Class of Device.
  func peripheralType(for peripheral: BluetoothPeripheral) -> PeripheralType {
    if let override = typeOverrides[peripheral.id] { return override }
    return PeripheralType.detect(name: peripheral.name, classOfDevice: deviceClasses[peripheral.id])
  }

  /// Set (or, with `nil`, clear → back to automatic) the icon/type override for
  /// a peripheral address. Persisted immediately via the `typeOverrides` didSet.
  func setTypeOverride(_ type: PeripheralType?, for id: String) {
    let apply: () -> Void = { [weak self] in
      guard let self = self else { return }
      if let type {
        self.typeOverrides[id] = type
      } else {
        self.typeOverrides.removeValue(forKey: id)
      }
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
  }

  // MARK: - Initialization

  private override init() {
    super.init()
    loadPeripherals()
    loadTypeOverrides()
    loadDeviceClasses()
    fetchConnectedPeripherals()
    registerForSystemBluetoothConnects()
    setupSleepRelease()
  }

  /// Wire the sleep/wake hooks: snapshot (and, when configured, release) held
  /// peripherals just before sleep, and reclaim them on wake.
  private func setupSleepRelease() {
    sleepMonitor.onWillSleep = { [weak self] in
      self?.prepareForSleep()
    }
    sleepMonitor.onDidWake = { [weak self] in
      self?.reclaimPeripheralsAfterWake()
    }
    sleepMonitor.start()
  }

  /// Runs (on main) from `SleepMonitor` immediately before sleep, with the
  /// power transition held until it returns. Two jobs:
  ///
  /// 1. Snapshot the registered peripherals currently connected to this Mac
  ///    into `connectedBeforeSleep`, so `reclaimPeripheralsAfterWake` can try
  ///    to get *whatever we were using* back on wake — not just the subset we
  ///    actively handed off. This is what recovers a device that drops on a
  ///    lid-close with no peer to hand it to and then won't reconnect (the
  ///    macOS-side bug the watcher exists for).
  ///
  /// 2. When `releaseOnSleep` is set and a trusted (non-mismatched) peer is
  ///    *registered*, release each held peripheral — so it's freed rather than
  ///    left latched to a host that's about to be unreachable, and the other
  ///    Mac can take it on its next wake without a power-cycle. We deliberately
  ///    do *not* require the peer to be reachable this instant: if it is, we
  ///    also push it the released set so the handoff is immediate (job 3); if it
  ///    isn't (asleep, off the network), freeing the peripheral still lets that
  ///    Mac adopt it whenever it wakes, and our own `reclaimPeripheralsAfterWake`
  ///    brings back anything it didn't take. A lone Mac with no registered peer
  ///    keeps its active connection because there is nothing to hand over.
  ///
  /// 3. If a trusted peer is reachable right now, proactively push it the
  ///    released set (`executeAdoptReleased`) so it grabs them immediately
  ///    instead of waiting to notice we're gone. Best-effort; see below.
  ///
  /// The IOBluetooth reads/disconnects run synchronously on `bluetoothQueue` (the
  /// only place IOBluetooth is touched) so they land before the radio powers
  /// down.
  private func prepareForSleep() {
    connectedBeforeSleep = []
    peripheralsDisconnectedForSleep = []

    // Snapshot `peripherals` on main before hopping to the Bluetooth queue.
    let registered = peripherals
    guard !registered.isEmpty else { return }

    let networkStore = NetworkDeviceStore.shared
    // A trusted (non-mismatched) peer is *registered*, whether or not it's
    // reachable this instant.
    let hasTrustedPeer = networkStore.networkDevices.contains { $0.pendingFingerprint == nil }
    // The subset of that which is reachable *now* — the target for the
    // proactive push below.
    let presentPeer = networkStore.networkDevices.first(where: {
      $0.pendingFingerprint == nil && ($0.isActive || networkStore.isReachable($0.id))
    })
    // Release whenever a two-Mac handoff is configured — not only when the peer
    // is reachable this instant. The Bluetooth pairing is retained on both
    // Macs; only the active connection is closed.
    let shouldRelease =
      releaseOnSleep && PairingStore.shared.isPaired && hasTrustedPeer

    // If we're neither releasing nor going to chase peripherals on wake, skip
    // the IOBluetooth scan rather than block the (held) sleep transition to
    // build a `connectedBeforeSleep` snapshot no one will read.
    guard shouldRelease || autoReconnect else { return }

    var connectedIDs: [String] = []
    var releasedIDs: [String] = []
    bluetoothQueue.sync {
      for peripheral in registered {
        guard let device = IOBluetoothDevice(addressString: peripheral.id),
          device.isConnected()
        else { continue }
        connectedIDs.append(peripheral.id)
        guard shouldRelease else { continue }
        switch closeConnectionIfNeeded(device) {
        case .released:
          releasedIDs.append(peripheral.id)
        case .failed(let result):
          print("Before sleep: failed to disconnect \(peripheral.name): \(result)")
        }
      }
    }

    // Back on main (we never left it). Record what we were holding so the
    // wake reclaim can chase it, and reflect any releases in the UI.
    connectedBeforeSleep = Set(connectedIDs)
    peripheralsDisconnectedForSleep = Set(releasedIDs)
    for id in releasedIDs {
      beginReleaseLease(id, reclaimOnExpiry: false)
      setConnectionState(.disconnected, for: id)
    }
    if !connectedIDs.isEmpty {
      print("Before sleep: \(connectedIDs.count) connected, released \(releasedIDs.count)")
    }

    // Proactive handoff: we've just freed these locally, so ask the present
    // peer to take them right now instead of leaving it to notice we're gone
    // and adopt them. This is what makes the handoff feel immediate when the
    // other Mac is awake. Best-effort and layered on top of the release above
    // (which already happened): if the push is missed, the peer's reactive
    // adoption still recovers them. We briefly block the (held) sleep
    // transition for the receipt ack — once this returns the radio powers down
    // and any un-flushed frame is lost — but sleep anyway if it doesn't arrive
    // within the budget. The ack fires on a background queue, so blocking main
    // here can't deadlock the send.
    if let peer = presentPeer, !releasedIDs.isEmpty {
      let ackWait = DispatchSemaphore(value: 0)
      networkStore.executeAdoptReleased(addresses: releasedIDs, on: peer) { _ in
        ackWait.signal()
      }
      _ = ackWait.wait(timeout: .now() + Constants.sleepHandoffAckTimeout)
    }
  }

  /// Runs (on main) from `SleepMonitor` after wake. When auto-reconnect is on,
  /// arms the watcher for *everything this Mac was holding before sleep* and
  /// politely adopts other unheld peripherals only after the peer is proven
  /// absent. When off, performs one protected reconnect attempt for devices
  /// deliberately disconnected before sleep. Waits
  /// `Constants.wakeReclaimDelay` first so the network can reassociate (and
  /// paired devices get a moment to reconnect on their own) before any
  /// unreachable-looking peer gets a peripheral grabbed back.
  private func reclaimPeripheralsAfterWake() {
    let connected = connectedBeforeSleep
    let disconnectedForSleep = peripheralsDisconnectedForSleep
    connectedBeforeSleep = []
    peripheralsDisconnectedForSleep = []
    clearAllReleaseLeases()
    // Even with nothing held before sleep there can be work to do: the
    // adoption sweep below picks up whatever an absent peer was holding.
    guard !connected.isEmpty || (autoReconnect && !peripherals.isEmpty) else { return }

    // Connection states are stale across sleep — a peripheral we left paired
    // still reads `.connected`. Refresh from live IOBluetooth so the watcher
    // (and the Peripheral tab) see reality before we act on it.
    fetchConnectedPeripherals()

    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.wakeReclaimDelay) {
      [weak self] in
      guard let self = self else { return }

      if self.autoReconnect {
        for id in connected {
          guard self.peripherals.contains(where: { $0.id == id }) else { continue }
          self.armReconnect(id)
        }
        // The rest of the registered set lived on the peer (or nowhere). If
        // the peer is gone too, those peripherals are stranded — adopt them.
        // Already-armed reclaims above are not downgraded by this sweep.
        self.armAdoptionOfUnheldPeripherals()
        return
      }

      // Feature off: no watcher to arm — make one silent, HOLDS_ONE-protected
      // connection attempt for the devices we deliberately disconnected.
      self.reclaimReleasedPeripherals(disconnectedForSleep)
    }
  }

  /// One-shot, silent reconnect protected by a live `HOLDS_ONE` query. Used
  /// after wake when automatic retries are disabled, and when a peer-requested
  /// release lease expires without this Mac learning the final handoff result.
  private func reclaimReleasedPeripherals(_ addresses: Set<String>) {
    for id in addresses {
      guard let peripheral = peripherals.first(where: { $0.id == id }),
        connectionState(for: id) == .disconnected
      else { continue }
      guard let device = NetworkDeviceStore.shared.networkDevices.first,
        device.pendingFingerprint == nil,
        PairingStore.shared.isPaired
      else {
        // No trusted peer to ask — none registered, or one flagged as a TOFU
        // identity mismatch. Either way it's ours; reclaim directly.
        attemptConnection(to: peripheral, reportFailure: false, completion: nil)
        continue
      }
      NetworkDeviceStore.shared.executeHoldsOne(address: id, on: device) { [weak self] result in
        // Completion fires on the connection queue — hop back before touching
        // main-only connection state.
        DispatchQueue.main.async {
          guard let self = self else { return }
          // `.success` = peer holds it (in use over there) → leave it.
          // Any `.failure` (peer says no, or unreachable) → take it back.
          guard case .failure = result,
            self.connectionState(for: id) == .disconnected
          else { return }
          self.attemptConnection(to: peripheral, reportFailure: false, completion: nil)
        }
      }
    }
  }

  /// Whether this Mac currently has a live Bluetooth connection to the
  /// peripheral with `address`. Answered off the live IOBluetooth state on
  /// `bluetoothQueue`; the completion fires on that queue. Used by the peer's
  /// `HOLDS_ONE` query so its wake-time reclaim skips peripherals we hold.
  func isHoldingPeripheral(address: String, completion: @escaping (Bool) -> Void) {
    bluetoothQueue.async {
      let connected = IOBluetoothDevice(addressString: address)?.isConnected() ?? false
      completion(connected)
    }
  }

  /// Register for every Bluetooth connect the OS sees. A connection restored
  /// during an active release lease is closed again; otherwise the store takes
  /// a fresh snapshot so System Settings changes appear immediately.
  private func registerForSystemBluetoothConnects() {
    globalConnectObserver = IOBluetoothDevice.register(
      forConnectNotifications: self,
      selector: #selector(handleSystemBluetoothConnect(_:fromDevice:))
    )
  }

  @objc private func handleSystemBluetoothConnect(
    _ notification: IOBluetoothUserNotification,
    fromDevice device: IOBluetoothDevice
  ) {
    guard let address = device.addressString else {
      fetchConnectedPeripherals()
      return
    }
    DispatchQueue.main.async {
      guard self.hasActiveReleaseLease(address) else {
        self.fetchConnectedPeripherals()
        return
      }
      self.enforceReleaseLease(for: device, address: address)
    }
  }

  // MARK: - Public Methods

  /// Adds a peripheral to the managed list in connected state
  /// - Parameter peripheral: The peripheral to add
  func addPeripheral(_ peripheral: BluetoothPeripheral) {
    guard validateBluetoothState() else { return }
    guard validateDeviceExists(peripheral) else { return }

    let newPeripheral = peripheral
    peripherals.append(newPeripheral)
    // Resolve the new row's live connection state (and register its disconnect
    // observer) right away. Without this the row reads `.disconnected` until
    // the next snapshot — i.e. the user has to leave and re-open the tab to
    // see an already-connected peripheral show as connected.
    fetchConnectedPeripherals()
  }

  /// Disconnects `peripheral` without creating or deleting a Bluetooth pair.
  /// `closeConnection()` is synchronous bluetoothd IPC, so it always runs on
  /// `bluetoothQueue`. Completion fires on main only after the live device is
  /// confirmed disconnected (or the attempt has failed).
  func releasePeripheral(
    _ peripheral: BluetoothPeripheral,
    reclaimOnLeaseExpiry: Bool = false,
    completion: ((Bool) -> Void)? = nil
  ) {
    let start = { [weak self] in
      guard let self = self else {
        completion?(false)
        return
      }
      self.disarmReconnect(peripheral.id)
      self.beginReleaseLease(
        peripheral.id, reclaimOnExpiry: reclaimOnLeaseExpiry)
      self.bluetoothQueue.async { [weak self] in
        self?.performReleasePeripheral(peripheral, completion: completion)
      }
    }
    if Thread.isMainThread { start() } else { DispatchQueue.main.async(execute: start) }
  }

  private func performReleasePeripheral(
    _ peripheral: BluetoothPeripheral,
    completion: ((Bool) -> Void)?
  ) {
    guard IOBluetoothHostController.default().powerState != kBluetoothHCIPowerStateOFF else {
      print("Bluetooth is off; \(peripheral.name) is already disconnected")
      markDisconnectedAfterRelease(peripheral.id)
      finishReleasePeripheral(
        peripheral, success: true, detail: "", completion: completion)
      return
    }
    guard let device = IOBluetoothDevice(addressString: peripheral.id) else {
      print("\(peripheral.name) is absent from the Bluetooth stack and already disconnected")
      markDisconnectedAfterRelease(peripheral.id)
      finishReleasePeripheral(
        peripheral, success: true, detail: "", completion: completion)
      return
    }

    switch closeConnectionIfNeeded(device) {
    case .released:
      print("Disconnected \(peripheral.name) without changing its pairing")
      markDisconnectedAfterRelease(peripheral.id)
      finishReleasePeripheral(
        peripheral, success: true, detail: "", completion: completion)
    case .failed(let result):
      print("Failed to disconnect \(peripheral.name): \(result)")
      finishReleasePeripheral(
        peripheral, success: false, detail: "closeConnection returned \(result)",
        completion: completion)
    }
  }

  /// Closes `device` without modifying its pairing record. A successful
  /// IOBluetooth return is final. When the command reports an error, a live
  /// state check may still prove that the connection disappeared concurrently,
  /// which also satisfies the release request.
  private func closeConnectionIfNeeded(_ device: IOBluetoothDevice) -> CloseConnectionOutcome {
    guard device.isConnected() else { return .released }
    let result = device.closeConnection()
    if result == kIOReturnSuccess || !device.isConnected() {
      return .released
    }
    return .failed(result)
  }

  private func finishReleasePeripheral(
    _ peripheral: BluetoothPeripheral,
    success: Bool,
    detail: String,
    completion: ((Bool) -> Void)?
  ) {
    DispatchQueue.main.async {
      if !success {
        self.clearReleaseLease(peripheral.id)
        self.setConnectionState(.connected, for: peripheral.id)
        self.setPeripheralError("Couldn't release.", for: peripheral.id)
        NotificationManager.showNotification(
          title: "Couldn't Release Peripheral",
          body:
            "Magic Switch couldn't disconnect \(peripheral.name) from this Mac (\(detail)). Its Bluetooth pairing was left unchanged.",
          identifier: "release-failed-\(peripheral.id)"
        )
      }
      completion?(success)
    }
  }

  /// Land `.disconnected` after a release — unless the row is mid-`.releasing`:
  /// the handoffs paint that before releasing (it's what keeps the re-entrancy
  /// guards seeing an in-flight transfer while the queue works) and own the
  /// row until their terminal branch resolves it.
  private func markDisconnectedAfterRelease(_ id: String) {
    let apply: () -> Void = { [weak self] in
      guard let self = self else { return }
      guard self.connectionStates[id] != .releasing else { return }
      self.setConnectionState(.disconnected, for: id)
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
  }

  /// Completely remove device from list
  func removeFromList(_ peripheral: BluetoothPeripheral) {
    guard peripherals.contains(where: { $0.id == peripheral.id }) else {
      print("\(peripheral.name) does not exist in the list")
      return
    }
    peripherals.removeAll { $0.id == peripheral.id }
    // No longer ours — stop watching and forget any pending release lease.
    disarmReconnect(peripheral.id)
    clearReleaseLease(peripheral.id)
    print("\(peripheral.name) has been removed from the list")
  }

  /// Moves `peripheral` per `direction`. `toggle` is the dropdown row's click
  /// behavior: send it if it's on this Mac, take it if it isn't. `take` and
  /// `send` skip a peripheral that's already on the right Mac, so scripted
  /// triggers can repeat them safely. Any direction is ignored mid-handoff.
  /// Falls back to a plain local connection when there's no switchable peer to take
  /// from.
  func switchPeripheral(_ peripheral: BluetoothPeripheral, direction: SwitchDirection) {
    let networkStore = NetworkDeviceStore.shared
    let canSwitch = networkStore.networkDevices.contains { networkStore.isSwitchable($0) }
    switch connectionState(for: peripheral.id) {
    case .connected:
      guard direction != .take else { return }
      // The dropdown greys out a connected row when no Mac is reachable, and
      // for the same reason a scripted send must refuse here: with no peer to
      // hand to, `sendPeripheralToPeer` falls back to a plain local release,
      // stranding the peripheral on neither Mac. The fixed identifier
      // collapses a multi-peripheral command into one notification.
      guard canSwitch else {
        NotificationManager.showNotification(
          title: "Can't Switch",
          body: "The other Mac isn't reachable — keeping peripherals on this Mac.",
          identifier: "switch-no-peer"
        )
        return
      }
      sendPeripheralToPeer(peripheral)
    case .disconnected:
      guard direction != .send else { return }
      if canSwitch {
        takePeripheralFromPeer(peripheral)
      } else {
        // No peer to ask — connect it to this Mac directly over Bluetooth.
        connectPeripheral(peripheral)
      }
    case .connecting, .releasing:
      break  // handoff in flight
    }
  }

  /// Asks the peer to release just this peripheral, then connects it
  /// locally. Used by the Peripheral tab's "Connect to PC" button and by
  /// the right-click menu's per-peripheral switch. Apple's Magic devices
  /// only honor one active host at a time, so the source connection must close
  /// before this Mac calls `openConnection()`.
  ///
  /// Falls back to a plain local connection if there's no paired peer, we're not
  /// paired ourselves, or the peer can't be reached — whether Bonjour
  /// already marked it inactive or it only turns out to be unreachable when
  /// we try to send (e.g. the other laptop's lid just closed).
  ///
  /// If the take fails — or the peer releases but the local connect doesn't
  /// take (a stuck device needing a power-cycle) — the auto-reconnect watcher
  /// keeps trying, gated by `HOLDS_ONE` so it never grabs a device the peer is
  /// actually holding.
  func takePeripheralFromPeer(_ peripheral: BluetoothPeripheral) {
    let networkStore = NetworkDeviceStore.shared
    guard let device = networkStore.networkDevices.first,
      PairingStore.shared.isPaired,
      device.isActive
    else {
      connectPeripheral(peripheral)
      return
    }

    // Peripheral is arriving at this Mac — flash the receiving arrow, the same
    // signal the full-set take raises on the menu-bar icon.
    NotificationCenter.default.post(name: .magicSwitchPeripheralIncoming, object: nil)
    setConnectionState(.connecting, for: peripheral.id)
    networkStore.executeUnregisterOne(address: peripheral.id, on: device) {
      [weak self] result in
      guard let self = self else { return }
      switch result {
      case .success:
        // Peer released it; grab it locally. Arm the watcher too, so a local
        // connect that fails (e.g. the device is in the stuck state and needs
        // a power-cycle) keeps retrying instead of leaving it on neither Mac.
        // It self-disarms once we're connected.
        self.connectPeripheral(peripheral)
        self.armReconnect(peripheral.id)
      case .failure(.connectionFailed), .failure(.connectTimeout):
        // We never got a TCP connection up, so the peer's machine is
        // unreachable (asleep, off the network, app not running) and isn't
        // holding the peripheral anymore — a Mac that drops off the network
        // has already released its Bluetooth devices. Connect locally instead
        // of stranding the user with an error they can't act on, and arm the
        // watcher as the same retry safety net. We deliberately don't grab on
        // post-connect failures (next case): if the connection opened, the
        // peer's machine is awake and may still actively hold the peripheral.
        self.connectPeripheral(peripheral)
        self.armReconnect(peripheral.id)
      case .failure(let err):
        // Reachable peer but the release errored, so we can't be sure it let
        // go. Don't grab it outright (that could yank it from a peer that did
        // take it); arm the HOLDS_ONE-gated watcher, which reclaims it only
        // once the peer confirms it isn't holding it — and recovers the case
        // where the peer released but the ack was lost.
        self.setConnectionState(.disconnected, for: peripheral.id)
        self.armReconnect(peripheral.id)
        self.setPeripheralError("Switch failed.", for: peripheral.id)
        NotificationManager.showNotification(
          title: "Couldn't Switch",
          body:
            "Couldn't ask \(device.name) to release \(peripheral.name): \(err.userMessage)",
          identifier: "take-failed-\(peripheral.id)"
        )
      }
    }
  }

  /// The inverse direction: confirm the peripheral disconnected locally, then
  /// ask the peer to take it.
  /// Used by the Peripheral tab's "Remove from PC" button and by the
  /// right-click menu's per-peripheral switch when the peripheral is
  /// currently on this Mac.
  ///
  /// Preflights the peer with a `.ping` *before* releasing anything: `isActive`
  /// (Bonjour) can lag reality by the mDNS TTL, so a PING that handshakes and
  /// acks is the authoritative "the peer's app is up and will accept a command"
  /// check. If it fails we keep the peripheral on this Mac untouched rather than
  /// release it into a peer that can't pick it up (stranding it on neither).
  /// Falls back to a plain local disconnect only when there's no paired peer to
  /// hand to. Mirrors the full-set handoff preflight in
  /// `AppDelegate.handleSwitchAction`.
  ///
  /// If the peer dies *after* the preflight but before it takes the peripheral,
  /// the same public connection path rolls it back onto this Mac.
  func sendPeripheralToPeer(_ peripheral: BluetoothPeripheral) {
    let networkStore = NetworkDeviceStore.shared
    guard let device = networkStore.networkDevices.first, PairingStore.shared.isPaired else {
      // No peer to hand off to — a plain disconnect is still non-destructive.
      releasePeripheral(peripheral)
      return
    }
    // Show "Releasing…" right away so the row greys out and stops accepting
    // clicks while the preflight below runs — it can take up to 5s, and until
    // it returns the button would otherwise still read "Release". On preflight
    // failure we revert to `.connected`; on success `performSendHandoff`
    // retains `.releasing` until the peer reports its connection result.
    setConnectionState(.releasing, for: peripheral.id)
    networkStore.executeCommand(.ping, on: device) { [weak self] preflight in
      DispatchQueue.main.async {
        guard let self = self else { return }
        switch preflight {
        case .failure(let err):
          // Peer unreachable — nothing released, peripheral stays on this Mac.
          self.setConnectionState(.connected, for: peripheral.id)
          self.setPeripheralError("Other Mac unreachable.", for: peripheral.id)
          NotificationManager.showNotification(
            title: "Switch Cancelled",
            body:
              "Couldn't reach \(device.name) (\(err.userMessage)) — keeping \(peripheral.name) on this Mac.",
            identifier: "send-preflight-failed-\(peripheral.id)"
          )
        case .success:
          self.performSendHandoff(peripheral, to: device)
        }
      }
    }
  }

  /// Release `peripheral` locally, then ask the peer to take it. Split out of
  /// `sendPeripheralToPeer` so the
  /// `.ping` preflight gates entry — by the time we get here the peer has just
  /// acked, but it can still die before `CONNECT_ONE`, so any failure reconnects
  /// this Mac rather than stranding the peripheral.
  private func performSendHandoff(_ peripheral: BluetoothPeripheral, to device: NetworkDevice) {
    // Peripheral is leaving this Mac for the peer — flash the sending arrow.
    NotificationCenter.default.post(name: .magicSwitchPeripheralOutgoing, object: nil)
    releasePeripheral(peripheral) { [weak self] success in
      guard let self = self else { return }
      guard success else {
        self.setConnectionState(.connected, for: peripheral.id)
        return
      }
      self.continueSendHandoff(peripheral, to: device)
    }
  }

  /// Rest of the send handoff, entered once the local release has been
  /// issued. The row has read "Releasing…" since `sendPeripheralToPeer`
  /// painted it (the release path leaves `.releasing` rows alone); the
  /// disconnect notification and the periodic fetch both skip a `.releasing`
  /// row, so it persists until a terminal branch resolves it.
  private func continueSendHandoff(_ peripheral: BluetoothPeripheral, to device: NetworkDevice) {
    let networkStore = NetworkDeviceStore.shared
    // Re-assert defensively — the mirror of the peer's "Connecting…".
    setConnectionState(.releasing, for: peripheral.id)
    networkStore.executeConnectOne(address: peripheral.id, on: device) { [weak self] result in
      guard let self = self else { return }
      switch result {
      case .success:
        // Keep the lease alive for its remaining window so an automatic source
        // reconnect cannot steal the device back while the peer settles.
        self.setConnectionState(.disconnected, for: peripheral.id)
      case .failure(let err):
        // The synchronized protocol reports connection completion, so any
        // failure rolls back locally. `connectPeripheral` clears the lease
        // before calling the public, non-destructive `openConnection()` API.
        self.connectPeripheral(peripheral)
        self.armReconnect(peripheral.id)
        NotificationManager.showNotification(
          title: "Couldn't Switch",
          body:
            "Couldn't hand \(peripheral.name) to \(device.name) (\(err.userMessage)); reconnecting it to this Mac.",
          identifier: "send-connect-failed-\(peripheral.id)"
        )
      }
    }
  }

  // MARK: - Full-Set Handoff Display

  /// Mark every registered peripheral "Releasing…" for the menu-bar full-set
  /// handoff (the per-peripheral send drives its own row in `performSendHandoff`).
  /// Call before local releases; pair with `finishFullSetRelease(success:)`.
  func beginFullSetRelease() {
    for peripheral in peripherals {
      setConnectionState(.releasing, for: peripheral.id)
    }
  }

  /// End the full-set "Releasing…" display. On success the peripherals now live
  /// on the peer, so they read `.disconnected`; on a non-success that didn't
  /// actually move them (e.g. the local disconnect failed), restore the live
  /// state. The `CONNECT_ALL`-failure rollback reconnects locally via
  /// `connectPeripheral` instead, which clears the row itself — don't call this
  /// there.
  func finishFullSetRelease(success: Bool) {
    if success {
      for peripheral in peripherals {
        setConnectionState(.disconnected, for: peripheral.id)
      }
    } else {
      fetchConnectedPeripherals(overrideTransient: true)
    }
  }

  func connectPeripheral(_ peripheral: BluetoothPeripheral) {
    attemptConnection(to: peripheral, reportFailure: true, completion: nil)
  }

  /// Connects a peripheral that the user has already paired in System
  /// Settings. The completion reports the live result of synchronous
  /// `openConnection()` and always fires on main.
  func connectPeripheral(
    _ peripheral: BluetoothPeripheral,
    completion: ((Bool) -> Void)?
  ) {
    attemptConnection(to: peripheral, reportFailure: true, completion: completion)
  }

  private func attemptConnection(
    to peripheral: BluetoothPeripheral,
    reportFailure: Bool,
    completion: ((Bool) -> Void)?
  ) {
    let start = { [weak self] in
      guard let self = self else {
        completion?(false)
        return
      }

      // A local takeover or rollback supersedes any prior instruction to keep
      // this device away from this Mac.
      self.clearReleaseLease(peripheral.id)
      self.setConnectionState(.connecting, for: peripheral.id)
      let attempt = self.beginConnectAttempt(for: peripheral.id)

      self.bluetoothQueue.async { [weak self] in
        guard let self = self else { return }

        guard IOBluetoothHostController.default().powerState != kBluetoothHCIPowerStateOFF else {
          print("Bluetooth is turned off")
          self.finishConnectAttempt(
            peripheral: peripheral, success: false,
            inline: "Bluetooth is off.",
            detail: "Turn on Bluetooth, then try again.",
            reportFailure: reportFailure, terminal: false,
            attempt: attempt, completion: completion)
          return
        }

        guard let device = IOBluetoothDevice(addressString: peripheral.id) else {
          print("\(peripheral.name) not found")
          self.finishConnectAttempt(
            peripheral: peripheral, success: false,
            inline: "Not found.",
            detail:
              "\(peripheral.name) isn't known to this Mac. Pair it in System Settings → Bluetooth first.",
            reportFailure: reportFailure, terminal: true,
            attempt: attempt, completion: completion)
          return
        }

        guard device.isPaired() else {
          print("\(peripheral.name) is not paired with this Mac")
          self.finishConnectAttempt(
            peripheral: peripheral, success: false,
            inline: "Not paired on this Mac.",
            detail:
              "\(peripheral.name) must be paired with this Mac in System Settings → Bluetooth before Magic Switch can connect it.",
            reportFailure: reportFailure, terminal: true,
            attempt: attempt, completion: completion)
          return
        }

        var result = kIOReturnSuccess
        if !device.isConnected() {
          result = device.openConnection()
        }
        let connected = device.isConnected()
        if connected {
          print("Connected \(peripheral.name) without changing its pairing")
          self.finishConnectAttempt(
            peripheral: peripheral, success: true,
            inline: "", detail: "", reportFailure: reportFailure, terminal: false,
            attempt: attempt, device: device, completion: completion)
        } else {
          print("openConnection to \(peripheral.name) failed: \(result)")
          self.finishConnectAttempt(
            peripheral: peripheral, success: false,
            inline: "Couldn't connect.",
            detail:
              "Couldn't connect \(peripheral.name) (error \(result)). It may be off, out of range, or connected to your other Mac. Its Bluetooth pairing was left unchanged.",
            reportFailure: reportFailure, terminal: false,
            attempt: attempt, completion: completion)
        }
      }
    }
    if Thread.isMainThread { start() } else { DispatchQueue.main.async(execute: start) }
  }

  func fetchConnectedPeripherals() {
    fetchConnectedPeripherals(overrideTransient: false)
  }

  /// - Parameter overrideTransient: when `true`, a live read replaces even an
  ///   in-flight `.connecting`/`.releasing` state. `false` (the usual path)
  ///   protects those transients from a stale snapshot (the Peripheral tab
  ///   polls this on a timer); `finishFullSetRelease(success:)` passes `true`
  ///   to restore the real state after an aborted handoff.
  private func fetchConnectedPeripherals(overrideTransient: Bool) {
    let runSnapshot: ([String]) -> Void = { [weak self] registeredIDs in
      guard let self = self else { return }
      self.bluetoothQueue.async {
        guard IOBluetoothHostController.default().powerState != kBluetoothHCIPowerStateOFF else {
          print("Bluetooth is turned off")
          return
        }

        guard let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
          print("No paired peripherals found")
          return
        }

        var paired: [BluetoothPeripheral] = []
        var connectedAddresses: Set<String> = []
        var classes: [String: UInt32] = [:]

        for device in pairedDevices {
          guard let address = device.addressString else { continue }
          if device.isConnected() {
            connectedAddresses.insert(address)
          }
          classes[address] = UInt32(device.classOfDevice)
          paired.append(
            BluetoothPeripheral(id: address, name: device.name ?? "Unknown Device")
          )
        }

        // Registered peripherals only. Every other connected Bluetooth device
        // (headphones, a game controller) may also publish a level no view
        // reads, and each one is another value that can change and make the
        // published dict unequal — i.e. an `objectWillChange` that re-renders
        // every observer for nothing.
        let battery = PeripheralBattery.levels(
          forAddresses: registeredIDs.filter { connectedAddresses.contains($0) })

        DispatchQueue.main.async {
          // Snapshot all paired devices; `availablePeripherals` filters out
          // registered ones at read time. Filtering here instead would mean
          // unregistering a peripheral can't immediately surface it under
          // "Available" until the next fetch (e.g. tab switch).
          // Assign only on change. The Peripheral tab polls this on a timer, so
          // an unconditional reassign would fire `objectWillChange` every tick
          // (needless re-renders, and it could dismiss an open type picker).
          if self.discoveredPeripherals != paired { self.discoveredPeripherals = paired }
          let mergedClasses = self.deviceClasses.merging(classes) { _, live in live }
          if self.deviceClasses != mergedClasses { self.deviceClasses = mergedClasses }
          if self.batteryLevels != battery { self.batteryLevels = battery }
          // Renaming a device in System Settings → Bluetooth should propagate
          // to our stored list (and thus the dropdown / Settings), so reconcile
          // registered names against the live ones we just read.
          self.refreshRegisteredNames(from: paired)
          for id in registeredIDs {
            let isConnected = connectedAddresses.contains(id)
            if isConnected, self.hasActiveReleaseLease(id) {
              if let device = IOBluetoothDevice(addressString: id) {
                self.enforceReleaseLease(for: device, address: id)
              }
              if self.connectionStates[id] != .releasing {
                self.connectionStates[id] = .disconnected
              }
              continue
            }
            // Don't overwrite an in-flight .connecting/.releasing state with a
            // stale read (unless a caller explicitly wants the live value).
            if !overrideTransient,
              self.connectionStates[id] == .connecting || self.connectionStates[id] == .releasing
            {
              continue
            }
            let newState: PeripheralConnectionState = isConnected ? .connected : .disconnected
            if self.connectionStates[id] != newState { self.connectionStates[id] = newState }
            if isConnected {
              if self.disconnectObservers[id] == nil,
                let device = IOBluetoothDevice(addressString: id)
              {
                self.registerForDisconnect(device: device, address: id)
              }
              // It's back on its own (e.g. macOS restored a paired device
              // on power-on, surfaced via the global connect observer). Adopt
              // it event-driven and stop watching, instead of waiting for the
              // next probe tick to notice.
              self.disarmReconnect(id)
            }
          }
        }
      }
    }

    if Thread.isMainThread {
      runSnapshot(peripherals.map { $0.id })
    } else {
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        runSnapshot(self.peripherals.map { $0.id })
      }
    }
  }

  /// Updates the peripheral list with new data from sync
  /// - Parameter newPeripherals: Array of peripherals to update with
  func updatePeripherals(_ newPeripherals: [BluetoothPeripheral]) {
    // Cap inbound list size; reject larger payloads outright.
    guard newPeripherals.count <= 64 else {
      print("Rejecting peripheral sync: list exceeds cap of 64")
      return
    }

    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.updatePeripherals(newPeripherals)
      }
      return
    }

    peripherals = newPeripherals
  }

  // MARK: - Connection Tracking

  /// Signature must be `(IOBluetoothUserNotification, IOBluetoothDevice)`.
  @objc private func handlePeripheralDisconnected(
    _ notification: IOBluetoothUserNotification,
    fromDevice device: IOBluetoothDevice
  ) {
    notification.unregister()
    let address = device.addressString ?? ""
    DispatchQueue.main.async {
      self.disconnectObservers.removeValue(forKey: address)
      // Don't clobber an in-flight transient: a fresh `.connecting` attempt
      // from a pre-empt path, or a `.releasing` handoff whose own release
      // *caused* this disconnect (the send path resolves that row itself).
      guard self.connectionStates[address] != .connecting,
        self.connectionStates[address] != .releasing
      else { return }
      self.connectionStates[address] = .disconnected
      if self.hasActiveReleaseLease(address) {
        // Keep the deadline state intact. macOS can reconnect and disconnect
        // the same device repeatedly during a handoff, and every notification
        // within the lease belongs to that deliberate release.
        return
      }
      // Genuine drop of a peripheral that should be on this Mac: start trying
      // to get it back. `armReconnect` no-ops when the feature is off or the
      // peripheral isn't registered to us.
      self.armReconnect(address)
    }
  }

  private func registerForDisconnect(device: IOBluetoothDevice, address: String) {
    guard
      let observer = device.register(
        forDisconnectNotification: self,
        selector: #selector(handlePeripheralDisconnected(_:fromDevice:))
      )
    else {
      return
    }
    DispatchQueue.main.async {
      self.disconnectObservers[address]?.unregister()
      self.disconnectObservers[address] = observer
    }
  }

  private func setConnectionState(_ state: PeripheralConnectionState, for id: String) {
    let apply: () -> Void = { [weak self] in
      guard let self = self else { return }
      self.connectionStates[id] = state
      // A fresh attempt (.connecting) or a success (.connected) clears any prior
      // inline error; a failure that ends in .disconnected keeps it on screen.
      if state != .disconnected { self.clearPeripheralError(id) }
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
  }

  /// Applies the result of one synchronous connection attempt. Attempt tokens
  /// keep an older queued `openConnection()` from overwriting a newer user or
  /// peer request for the same address.
  private func finishConnectAttempt(
    peripheral: BluetoothPeripheral,
    success: Bool,
    inline: String,
    detail: String,
    reportFailure: Bool,
    terminal: Bool,
    attempt: UInt64,
    device: IOBluetoothDevice? = nil,
    completion: ((Bool) -> Void)?
  ) {
    DispatchQueue.main.async {
      guard self.connectAttemptTokens[peripheral.id] == attempt else {
        completion?(false)
        return
      }
      self.connectAttemptTokens.removeValue(forKey: peripheral.id)

      if success {
        self.setConnectionState(.connected, for: peripheral.id)
        if let device {
          self.registerForDisconnect(device: device, address: peripheral.id)
        }
        self.disarmReconnect(peripheral.id)
        completion?(true)
        return
      }

      self.setConnectionState(.disconnected, for: peripheral.id)
      if terminal {
        // A missing local pairing cannot heal through retries. Stop both
        // reclaim and adoption loops until the user pairs the device manually.
        self.disarmReconnect(peripheral.id)
      }
      if reportFailure || terminal {
        self.setPeripheralError(inline, for: peripheral.id)
        if self.reconnectWatchlist[peripheral.id] == nil {
          NotificationManager.showNotification(
            title: "Couldn't Connect",
            body: detail,
            identifier: "connect-failed-\(peripheral.id)"
          )
        }
      }
      completion?(false)
    }
  }

  /// Mints the token identifying one connection attempt. Newer attempts always
  /// supersede older queued results for the same address.
  private func beginConnectAttempt(for id: String) -> UInt64 {
    attemptTokenLock.lock()
    connectAttemptCounter += 1
    let token = connectAttemptCounter
    attemptTokenLock.unlock()
    let apply: () -> Void = { [weak self] in
      guard let self = self else { return }
      // Newest wins: an off-main mint's record can arrive after a later
      // main-side mint applied inline, and must not roll the map back to the
      // older attempt (which would orphan the newer one's failure paths).
      if (self.connectAttemptTokens[id] ?? 0) < token {
        self.connectAttemptTokens[id] = token
      }
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    return token
  }

  /// Set the inline error for a peripheral, and fade it after 5s so it doesn't
  /// linger on the row. `setConnectionState` clears it sooner on a new attempt.
  private func setPeripheralError(_ message: String, for id: String) {
    let apply: () -> Void = { [weak self] in
      guard let self = self else { return }
      self.peripheralOperationError[id] = message
      self.peripheralErrorTimers[id]?.cancel()
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.schedule(deadline: .now() + 5)
      timer.setEventHandler { [weak self] in self?.clearPeripheralError(id) }
      timer.resume()
      self.peripheralErrorTimers[id] = timer
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
  }

  /// Clear a peripheral's inline error and cancel its fade timer (main thread).
  private func clearPeripheralError(_ id: String) {
    peripheralErrorTimers[id]?.cancel()
    peripheralErrorTimers[id] = nil
    peripheralOperationError[id] = nil
  }

  // MARK: - Auto-Reconnect Watcher

  /// Arm the watcher in *adoption* mode for every registered peripheral not
  /// currently connected to this Mac. Called when the peer stops being part
  /// of the picture: this Mac just woke (the peer may have slept while we
  /// did), or the reachability poll watched the peer drop off the network.
  /// Arming broadly is safe because adoption only ever takes from a provably
  /// absent peer (see `continueAdoption`): entries against a live peer stand
  /// down on their first answered probe, and `armReconnect` never downgrades
  /// an existing reclaim entry to an adoption.
  func armAdoptionOfUnheldPeripherals() {
    // Main-only state; called from the reachability poll's completion too.
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.armAdoptionOfUnheldPeripherals() }
      return
    }
    guard autoReconnect else { return }
    for peripheral in peripherals where connectionState(for: peripheral.id) == .disconnected {
      armReconnect(peripheral.id, adoption: true)
    }
  }

  /// Arm the watcher for `id`: it retries on a fixed cadence after confirming
  /// the peer is not using the device. No-op when
  /// the feature is off or the peripheral isn't registered to us. Preserves the
  /// original arm time on re-arm so the `reconnectMaxWindow` bound counts from
  /// the first drop. `adoption` marks the polite no-prior-claim flavour; it
  /// only applies to a *fresh* arm — re-arming an existing reclaim as an
  /// adoption keeps the reclaim, while an explicit (non-adoption) re-arm
  /// upgrades an adoption to a full reclaim.
  private func armReconnect(_ id: String, adoption: Bool = false) {
    // The watcher dictionaries/sets and timer are main-only, but deliberate
    // releases (`releasePeripheral` during a handoff) reach the watcher from the
    // outgoing-connection queue — hop to main so we never mutate this state
    // concurrently with `reconnectTick` / `handlePeripheralDisconnected`.
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.armReconnect(id, adoption: adoption) }
      return
    }
    guard autoReconnect, peripherals.contains(where: { $0.id == id }),
      !hasActiveReleaseLease(id)
    else { return }
    if reconnectWatchlist[id] == nil {
      reconnectWatchlist[id] = Date()
      if adoption { adoptionProgress[id] = AdoptionProgress() }
      print("Auto-reconnect: watching \(id)\(adoption ? " (adoption)" : "")")
      // If the timer is mid-interval, pull the next probe forward so this
      // newcomer is checked promptly rather than waiting out the rest of the
      // current interval.
      reconnectTimer?.schedule(deadline: .now(), leeway: Constants.reconnectProbeLeeway)
    } else if !adoption {
      // An explicit claim (genuine drop, failed handoff, wake reclaim) on an
      // entry armed as adoption upgrades it: from here on, a live peer
      // answering "not holding" no longer stands the watcher down.
      adoptionProgress.removeValue(forKey: id)
    }
    startReconnectTimerIfNeeded()
  }

  /// Arm the auto-reconnect watcher for `id` as a *reclaim* (prior claim) —
  /// the same retry/rollback safety net `takePeripheralFromPeer` arms
  /// internally. Exposed for `AppDelegate`'s full-set takeover, which drives
  /// the status-bar transfer icon itself and so can't route through
  /// `takePeripheralFromPeer`. A reclaim is HOLDS_ONE-gated (it never grabs a
  /// peripheral the peer confirms it's holding) and retries for the full
  /// `reconnectMaxWindow`, so a temporarily unavailable device comes back the
  /// moment the user power-cycles it.
  func armReconnectForTakeover(_ id: String) {
    armReconnect(id)
  }

  /// Stop watching `id` — it connected, moved to the peer, was removed, or
  /// timed out. Tears the timer down once nothing is left to watch.
  private func disarmReconnect(_ id: String) {
    // Main-only state; see `armReconnect`.
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.disarmReconnect(id) }
      return
    }
    reconnectInFlight.remove(id)
    adoptionProgress.removeValue(forKey: id)
    guard reconnectWatchlist.removeValue(forKey: id) != nil else { return }
    if reconnectWatchlist.isEmpty { stopReconnectTimer() }
  }

  private func beginReleaseLease(_ id: String, reclaimOnExpiry: Bool) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.beginReleaseLease(id, reclaimOnExpiry: reclaimOnExpiry)
      }
      return
    }
    let lease = ReleaseLease(
      expiresAt: Date().addingTimeInterval(Constants.handoffReleaseLease),
      reclaimOnExpiry: reclaimOnExpiry)
    releaseLeases[id] = lease
    releaseLeaseTimers[id]?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + Constants.handoffReleaseLease)
    timer.setEventHandler { [weak self] in
      self?.expireReleaseLease(id, expectedExpiry: lease.expiresAt)
    }
    timer.resume()
    releaseLeaseTimers[id] = timer
  }

  private func hasActiveReleaseLease(_ id: String) -> Bool {
    guard let lease = releaseLeases[id] else { return false }
    guard lease.expiresAt > Date() else {
      expireReleaseLease(id, expectedExpiry: lease.expiresAt)
      return false
    }
    return true
  }

  private func clearReleaseLease(_ id: String) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.clearReleaseLease(id) }
      return
    }
    releaseLeases.removeValue(forKey: id)
    releaseLeaseTimers.removeValue(forKey: id)?.cancel()
  }

  private func clearAllReleaseLeases() {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.clearAllReleaseLeases() }
      return
    }
    for timer in releaseLeaseTimers.values {
      timer.cancel()
    }
    releaseLeaseTimers.removeAll()
    releaseLeases.removeAll()
  }

  private func expireReleaseLease(_ id: String, expectedExpiry: Date) {
    guard let lease = releaseLeases[id], lease.expiresAt == expectedExpiry else { return }
    releaseLeases.removeValue(forKey: id)
    releaseLeaseTimers.removeValue(forKey: id)?.cancel()
    guard lease.reclaimOnExpiry,
      connectionState(for: id) == .disconnected
    else { return }
    reclaimReleasedPeripherals([id])
  }

  /// If macOS restores a connection on the source Mac during the handoff
  /// window, close it again without extending the lease or touching pairing.
  private func enforceReleaseLease(for device: IOBluetoothDevice, address: String) {
    guard hasActiveReleaseLease(address) else { return }
    bluetoothQueue.async { [weak self] in
      guard let self = self else { return }
      let outcome = self.closeConnectionIfNeeded(device)
      DispatchQueue.main.async {
        guard self.hasActiveReleaseLease(address) else { return }
        switch outcome {
        case .released:
          self.markDisconnectedAfterRelease(address)
        case .failed(let result):
          print("Release lease couldn't disconnect \(address): \(result)")
          self.setPeripheralError("Couldn't keep released.", for: address)
          NotificationManager.showNotification(
            title: "Bluetooth Handoff Interrupted",
            body:
              "macOS reconnected a peripheral during its handoff, and Magic Switch couldn't disconnect it again. Its pairing was left unchanged.",
            identifier: "release-lease-failed-\(address)")
        }
      }
    }
  }

  private func startReconnectTimerIfNeeded() {
    guard reconnectTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    // Fire immediately, then re-arm one-shot after each pass (see
    // `scheduleNextReconnectTick`). The immediate first tick keeps wake-time
    // reclaim and manual power-cycle recovery prompt.
    timer.schedule(deadline: .now(), leeway: Constants.reconnectProbeLeeway)
    timer.setEventHandler { [weak self] in
      guard let self = self else { return }
      self.reconnectTick()
      self.scheduleNextReconnectTick()
    }
    timer.resume()
    reconnectTimer = timer
  }

  /// Re-arm the (one-shot) probe timer for the next pass at the constant probe
  /// cadence. No-op when `reconnectTick` already tore the timer down (watchlist
  /// emptied / feature off).
  private func scheduleNextReconnectTick() {
    guard let timer = reconnectTimer else { return }
    timer.schedule(
      deadline: .now() + Constants.reconnectProbeInterval,
      leeway: Constants.reconnectProbeLeeway)
  }

  private func stopReconnectTimer() {
    reconnectTimer?.cancel()
    reconnectTimer = nil
  }

  /// One retry pass over the watchlist (runs on main). Drops entries that are
  /// connected, no longer ours, leased away, or past the window; otherwise
  /// asks the peer whether it holds the device before reconnecting. Iterates a snapshot because
  /// `disarmReconnect` mutates `reconnectWatchlist`.
  private func reconnectTick() {
    guard autoReconnect else {
      // Toggled off mid-flight — stand down.
      reconnectWatchlist.removeAll()
      reconnectInFlight.removeAll()
      stopReconnectTimer()
      return
    }
    let now = Date()
    for (id, armedAt) in reconnectWatchlist {
      if reconnectInFlight.contains(id) { continue }
      if hasActiveReleaseLease(id) { continue }
      guard let peripheral = peripherals.first(where: { $0.id == id }) else {
        disarmReconnect(id)
        continue
      }
      if now.timeIntervalSince(armedAt) > Constants.reconnectMaxWindow {
        print("Auto-reconnect: giving up on \(peripheral.name)")
        disarmReconnect(id)
        continue
      }
      switch connectionState(for: id) {
      case .connected:
        disarmReconnect(id)
      case .connecting, .releasing:
        continue  // an attempt / handoff is already in flight
      case .disconnected:
        reclaimIfReady(peripheral)
      }
    }
  }

  /// Begin one protected reconnect attempt. We deliberately do not gate this
  /// on RSSI: IOBluetooth reports 127 for disconnected devices, so that test
  /// prevents the very connection it is meant to enable.
  private func reclaimIfReady(_ peripheral: BluetoothPeripheral) {
    let id = peripheral.id
    reconnectInFlight.insert(id)
    reclaimIfPeerIsFree(peripheral)
  }

  /// Ask the peer (read-only `HOLDS_ONE`) whether it is using `peripheral`: if
  /// so, stop watching (it is legitimately theirs);
  /// otherwise — peer says no, or is unreachable — reconnect locally. This is
  /// the same guard the wake-reclaim uses: we never yank a peripheral the
  /// peer is actively using, and we never tell the peer to disconnect.
  private func reclaimIfPeerIsFree(_ peripheral: BluetoothPeripheral) {
    let id = peripheral.id
    guard PairingStore.shared.isPaired,
      let device = NetworkDeviceStore.shared.networkDevices.first,
      device.pendingFingerprint == nil
    else {
      reconnectInFlight.remove(id)
      if adoptionProgress[id] != nil {
        // No trusted peer to consult and no prior claim on the peripheral —
        // stand down rather than grab one whose holder we can't even ask.
        disarmReconnect(id)
        return
      }
      // No trusted peer to consult — none registered, or one flagged as a
      // TOFU identity mismatch. Either way it's ours; reclaim locally rather
      // than auto-probing an untrusted peer with our now-stale key.
      attemptConnection(to: peripheral, reportFailure: false, completion: nil)
      return
    }
    NetworkDeviceStore.shared.executeHoldsOne(address: id, on: device) { [weak self] result in
      // `executeHoldsOne`'s completion fires on the connection queue, not
      // main — hop back before touching watcher state.
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.reconnectInFlight.remove(id)
        switch result {
        case .success:
          // Peer is actively holding it — leave it there.
          print("Auto-reconnect: \(peripheral.name) held by \(device.name); leaving it")
          self.disarmReconnect(id)
        case .failure(let failure):
          guard self.reconnectWatchlist[id] != nil,
            self.connectionState(for: id) == .disconnected
          else { return }
          if self.adoptionProgress[id] != nil {
            self.continueAdoption(of: peripheral, after: failure)
            return
          }
          print("Auto-reconnect: reclaiming \(peripheral.name)")
          self.attemptConnection(to: peripheral, reportFailure: false, completion: nil)
        }
      }
    }
  }

  /// Adoption-flavoured continuation of `reclaimIfPeerIsFree`'s failure arm
  /// (runs on main). A reclaim takes the peripheral on *any* `HOLDS_ONE`
  /// failure; an adoption — no prior claim — takes it only once the peer is
  /// provably absent: unreachable at the connect layer for
  /// `adoptionRequiredAbsentStreak` consecutive probes. A peer that answers
  /// at all — an explicit "not holding" (`.remoteOperationFailed`) included —
  /// outranks us, so stand down and leave the move to its reclaim or to the user.
  /// Connection attempts are capped: repeated failures usually mean the
  /// device is busy with a peer we cannot reach.
  private func continueAdoption(of peripheral: BluetoothPeripheral, after failure: OutgoingFailure)
  {
    let id = peripheral.id
    guard var progress = adoptionProgress[id] else { return }
    switch failure {
    case .connectionFailed, .connectTimeout:
      progress.peerAbsentStreak += 1
    default:
      // The peer's machine accepted the TCP connection even though the probe
      // failed past that point — that's a live peer, not an absent one.
      print("Adoption: \(peripheral.name) — peer is up; standing down")
      disarmReconnect(id)
      return
    }
    guard progress.peerAbsentStreak >= Constants.adoptionRequiredAbsentStreak else {
      adoptionProgress[id] = progress
      return
    }
    guard progress.connectAttempts < Constants.adoptionMaxConnectAttempts else {
      print(
        "Adoption: giving up on \(peripheral.name) after \(progress.connectAttempts) connection attempts"
      )
      disarmReconnect(id)
      return
    }
    progress.connectAttempts += 1
    adoptionProgress[id] = progress
    print("Adoption: taking \(peripheral.name) (attempt \(progress.connectAttempts))")
    attemptConnection(to: peripheral, reportFailure: false, completion: nil)
  }

  // MARK: - Private Methods

  /// Reconcile registered peripheral names against the live paired-device list,
  /// so a rename in System Settings → Bluetooth shows up in our stored list.
  /// Only rewrites a name that actually changed to a non-empty live value, and
  /// leaves alone peripherals not currently present in the paired-device
  /// snapshot. Runs on main; assigning `peripherals` saves and re-renders.
  private func refreshRegisteredNames(from liveDevices: [BluetoothPeripheral]) {
    let liveNames = Dictionary(liveDevices.map { ($0.id, $0.name) }) { first, _ in first }
    var changed = false
    let refreshed = peripherals.map { peripheral -> BluetoothPeripheral in
      guard let live = liveNames[peripheral.id],
        !live.isEmpty, live != "Unknown Device", live != peripheral.name
      else { return peripheral }
      changed = true
      var updated = peripheral
      updated.name = live
      return updated
    }
    if changed { peripherals = refreshed }
  }

  private func savePeripherals() {
    do {
      let encoded = try JSONEncoder().encode(peripherals)
      peripheralsData = encoded
    } catch {
      print("Failed to save peripherals: \(error)")
    }
  }

  private func saveTypeOverrides() {
    do {
      typeOverridesData = try JSONEncoder().encode(typeOverrides)
    } catch {
      print("Failed to save type overrides: \(error)")
    }
  }

  private func loadTypeOverrides() {
    guard !typeOverridesData.isEmpty else { return }
    do {
      typeOverrides = try JSONDecoder().decode(
        [String: PeripheralType].self, from: typeOverridesData)
    } catch {
      print("Failed to load type overrides: \(error)")
    }
  }

  private func saveDeviceClasses() {
    do {
      deviceClassesData = try JSONEncoder().encode(deviceClasses)
    } catch {
      print("Failed to save device classes: \(error)")
    }
  }

  private func loadDeviceClasses() {
    guard !deviceClassesData.isEmpty else { return }
    do {
      deviceClasses = try JSONDecoder().decode([String: UInt32].self, from: deviceClassesData)
    } catch {
      print("Failed to load device classes: \(error)")
    }
  }

  private func loadPeripherals() {
    do {
      peripherals = try JSONDecoder().decode([BluetoothPeripheral].self, from: peripheralsData)
    } catch {
      print("Failed to load peripherals: \(error)")
    }
  }

  // MARK: - Helper Methods

  private func validateBluetoothState() -> Bool {
    let powerState = IOBluetoothHostController.default().powerState
    guard powerState != kBluetoothHCIPowerStateOFF else {
      print("Bluetooth is turned off")
      return false
    }
    return true
  }

  private func validateDeviceExists(_ peripheral: BluetoothPeripheral) -> Bool {
    guard IOBluetoothDevice(addressString: peripheral.id) != nil else {
      print("Device not found: \(peripheral.name)")
      return false
    }
    return true
  }

}

extension BluetoothPeripheralStore {
  /// Aggregate connection state across all registered peripherals.
  enum ConnectionStatus {
    case allConnected
    case allDisconnected
    case partial
  }

  /// Queries the live IOBluetooth state on `bluetoothQueue` and returns on
  /// main. Snapshots `peripherals` on main before hopping so we never read
  /// the `@Published` array from a background thread.
  func checkActualConnectionStatusAsync(completion: @escaping (ConnectionStatus) -> Void) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.checkActualConnectionStatusAsync(completion: completion)
      }
      return
    }

    let snapshot = peripherals
    bluetoothQueue.async {
      var connectedCount = 0
      var totalCount = 0
      for peripheral in snapshot {
        if let device = IOBluetoothDevice(addressString: peripheral.id) {
          totalCount += 1
          if device.isConnected() { connectedCount += 1 }
        }
      }
      let status: ConnectionStatus
      if totalCount == 0 || connectedCount == 0 {
        status = .allDisconnected
      } else if connectedCount == totalCount {
        status = .allConnected
      } else {
        status = .partial
      }
      DispatchQueue.main.async { completion(status) }
    }
  }
}
