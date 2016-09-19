Delegato = require 'delegato'
_ = require 'underscore-plus'
{Emitter, Disposable, CompositeDisposable, Range} = require 'atom'

settings = require './settings'
globalState = require './global-state'
{HoverElement} = require './hover'
{InputElement, SearchInputElement} = require './input'
{
  haveSomeSelection
  highlightRanges
  getVisibleBufferRange
  matchScopes
  isRangeContainsSomePoint

  debug
} = require './utils'
swrap = require './selection-wrapper'

OperationStack = require './operation-stack'
MarkManager = require './mark-manager'
ModeManager = require './mode-manager'
RegisterManager = require './register-manager'
SearchHistoryManager = require './search-history-manager'
CursorStyleManager = require './cursor-style-manager'
BlockwiseSelection = require './blockwise-selection'

packageScope = 'vim-mode-plus'

module.exports =
class VimState
  Delegato.includeInto(this)
  destroyed: false

  @delegatesProperty('mode', 'submode', toProperty: 'modeManager')
  @delegatesMethods('isMode', 'activate', toProperty: 'modeManager')
  @delegatesMethods('getCount', 'setCount', 'hasCount', toProperty: 'operationStack')

  constructor: (@main, @editor, @statusBarManager) ->
    @editorElement = @editor.element
    @emitter = new Emitter
    @subscriptions = new CompositeDisposable
    @modeManager = new ModeManager(this)
    @mark = new MarkManager(this)
    @register = new RegisterManager(this)
    @rangeMarkers = []
    @markerLayer = @editor.addMarkerLayer()
    @hover = new HoverElement().initialize(this)
    @hoverSearchCounter = new HoverElement().initialize(this)
    @searchHistory = new SearchHistoryManager(this)

    @input = new InputElement().initialize(this)
    @searchInput = new SearchInputElement().initialize(this)

    @operationStack = new OperationStack(this)
    @cursorStyleManager = new CursorStyleManager(this)
    @blockwiseSelections = []
    @observeSelection()

    @highlightSearchSubscription = @editorElement.onDidChangeScrollTop =>
      @refreshHighlightSearch()

    @editorElement.classList.add(packageScope)
    if settings.get('startInInsertMode') or matchScopes(@editorElement, settings.get('startInInsertModeScopes'))
      @activate('insert')
    else
      @activate('normal')

  subscribe: (args...) ->
    @operationStack.subscribe args...

  # BlockwiseSelections
  # -------------------------
  getBlockwiseSelections: ->
    @blockwiseSelections

  getLastBlockwiseSelection: ->
    _.last(@blockwiseSelections)

  getBlockwiseSelectionsOrderedByBufferPosition: ->
    @getBlockwiseSelections().sort (a, b) ->
      a.getStartSelection().compare(b.getStartSelection())

  clearBlockwiseSelections: ->
    @blockwiseSelections = []

  selectBlockwise: ->
    for selection in @editor.getSelections()
      @blockwiseSelections.push(new BlockwiseSelection(selection))
    @updateSelectionProperties()

  # Other
  # -------------------------
  selectLinewise: ->
    swrap.expandOverLine(@editor, preserveGoalColumn: true)

  setOperatorModifier: (modifier) ->
    @operationStack.setOperatorModifier(modifier)

  # Mark
  # -------------------------
  startCharInput: (@charInputAction) ->
    @inputCharSubscriptions = new CompositeDisposable()
    @inputCharSubscriptions.add @swapClassName('vim-mode-plus-input-char-waiting')
    @inputCharSubscriptions.add atom.commands.add @editorElement,
      'core:cancel': => @resetCharInput()

  setInputChar: (char) ->
    switch @charInputAction
      when 'save-mark'
        @mark.set(char, @editor.getCursorBufferPosition())
      when 'move-to-mark'
        @operationStack.run("MoveToMark", input: char)
      when 'move-to-mark-line'
        @operationStack.run("MoveToMarkLine", input: char)
    @resetCharInput()

  resetCharInput: ->
    @inputCharSubscriptions?.dispose()

  # -------------------------
  toggleClassList: (className, bool=undefined) ->
    @editorElement.classList.toggle(className, bool)

  swapClassName: (className) ->
    oldClassName = @editorElement.className
    @editorElement.className = className
    new Disposable =>
      @editorElement.className = oldClassName

  # All subscriptions here is celared on each operation finished.
  # -------------------------
  onDidChangeInput: (fn) -> @subscribe @input.onDidChange(fn)
  onDidConfirmInput: (fn) -> @subscribe @input.onDidConfirm(fn)
  onDidCancelInput: (fn) -> @subscribe @input.onDidCancel(fn)
  onDidUnfocusInput: (fn) -> @subscribe @input.onDidUnfocus(fn)
  onDidCommandInput: (fn) -> @subscribe @input.onDidCommand(fn)

  onDidChangeSearch: (fn) -> @subscribe @searchInput.onDidChange(fn)
  onDidConfirmSearch: (fn) -> @subscribe @searchInput.onDidConfirm(fn)
  onDidCancelSearch: (fn) -> @subscribe @searchInput.onDidCancel(fn)
  onDidUnfocusSearch: (fn) -> @subscribe @searchInput.onDidUnfocus(fn)
  onDidCommandSearch: (fn) -> @subscribe @searchInput.onDidCommand(fn)

  # Select and text mutation(Change)
  onDidSetTarget: (fn) -> @subscribe @emitter.on('did-set-target', fn)
  onWillSelectTarget: (fn) -> @subscribe @emitter.on('will-select-target', fn)
  onDidSelectTarget: (fn) -> @subscribe @emitter.on('did-select-target', fn)
  preemptWillSelectTarget: (fn) -> @subscribe @emitter.preempt('will-select-target', fn)
  preemptDidSelectTarget: (fn) -> @subscribe @emitter.preempt('did-select-target', fn)
  onDidRestoreCursorPositions: (fn) -> @subscribe @emitter.on('did-restore-cursor-positions', fn)

  onDidFinishOperation: (fn) -> @subscribe @emitter.on('did-finish-operation', fn)

  # Select list view
  onDidConfirmSelectList: (fn) -> @subscribe @emitter.on('did-confirm-select-list', fn)
  onDidCancelSelectList: (fn) -> @subscribe @emitter.on('did-cancel-select-list', fn)

  # Events
  # -------------------------
  onDidFailToSetTarget: (fn) -> @emitter.on('did-fail-to-set-target', fn)
  onDidDestroy: (fn) -> @emitter.on('did-destroy', fn)

  # * `fn` {Function} to be called when mark was set.
  #   * `name` Name of mark such as 'a'.
  #   * `bufferPosition`: bufferPosition where mark was set.
  #   * `editor`: editor where mark was set.
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  #
  #  Usage:
  #   onDidSetMark ({name, bufferPosition}) -> do something..
  onDidSetMark: (fn) -> @emitter.on('did-set-mark', fn)

  destroy: ->
    return if @destroyed
    @destroyed = true
    @subscriptions.dispose()

    if @editor.isAlive()
      @resetNormalMode()
      @reset()
      @editorElement.component?.setInputEnabled(true)
      @editorElement.classList.remove(packageScope, 'normal-mode')

    @hover?.destroy?()
    @hoverSearchCounter?.destroy?()
    @operationStack?.destroy?()
    @searchHistory?.destroy?()
    @cursorStyleManager?.destroy?()
    @input?.destroy?()
    @search?.destroy?()
    @modeManager?.destroy?()
    @operationRecords?.destroy?()
    @register?.destroy?
    @clearHighlightSearch()
    @clearRangeMarkers()
    @highlightSearchSubscription?.dispose()
    {
      @hover, @hoverSearchCounter, @operationStack,
      @searchHistory, @cursorStyleManager
      @input, @search, @modeManager, @operationRecords, @register
      @count, @rangeMarkers
      @editor, @editorElement, @subscriptions,
      @inputCharSubscriptions
      @highlightSearchSubscription
    } = {}
    @emitter.emit 'did-destroy'

  observeSelection: ->
    isInterestingEvent = ({target, type}) =>
      if @mode is 'insert'
        false
      else
        @editor? and
          target is @editorElement and
          not @isMode('visual', 'blockwise') and
          not type.startsWith('vim-mode-plus:')

    onInterestingEvent = (fn) ->
      (event) -> fn() if isInterestingEvent(event)

    _checkSelection = =>
      return if @operationStack.isProcessing()
      if haveSomeSelection(@editor)
        submode = swrap.detectVisualModeSubmode(@editor)
        if @isMode('visual', submode)
          @updateCursorsVisibility()
        else
          @activate('visual', submode)
      else
        @activate('normal') if @isMode('visual')

    _preserveCharacterwise = =>
      for selection in @editor.getSelections()
        swrap(selection).preserveCharacterwise()

    checkSelection = onInterestingEvent(_checkSelection)
    preserveCharacterwise = onInterestingEvent(_preserveCharacterwise)

    @editorElement.addEventListener('mouseup', checkSelection)
    @subscriptions.add new Disposable =>
      @editorElement.removeEventListener('mouseup', checkSelection)

    # [FIXME]
    # Hover position get wired when focus-change between more than two pane.
    # commenting out is far better than introducing Buggy behavior.
    # @subscriptions.add atom.commands.onWillDispatch(preserveCharacterwise)

    @subscriptions.add atom.commands.onDidDispatch(checkSelection)

  resetNormalMode: ({userInvocation}={}) ->
    if userInvocation ? false
      unless @editor.hasMultipleCursors()
        @clearRangeMarkers() if settings.get('clearRangeMarkerOnResetNormalMode')
        @main.clearHighlightSearchForEditors() if settings.get('clearHighlightSearchOnResetNormalMode')
    @editor.clearSelections()
    @activate('normal')

  reset: ->
    @resetCharInput()
    for marker in @markerLayer.getMarkers()
      marker.destroy()

    debug('marker length', @markerLayer.getMarkers().length)

    @register.reset()
    @searchHistory.reset()
    @hover.reset()
    @operationStack.reset()

  updateCursorsVisibility: ->
    @cursorStyleManager.refresh()

  updateSelectionProperties: ({force}={}) ->
    selections = @editor.getSelections()
    unless (force ? true)
      selections = selections.filter (selection) ->
        not swrap(selection).getCharacterwiseHeadPosition()?

    for selection in selections
      swrap(selection).preserveCharacterwise()

  # highlightSearch
  # -------------------------
  clearHighlightSearch: ->
    for marker in @highlightSearchMarkers ? []
      marker.destroy()
    @highlightSearchMarkers = null

  hasHighlightSearch: ->
    @highlightSearchMarkers?

  getHighlightSearch: ->
    @highlightSearchMarkers

  highlightSearch: (pattern, scanRange) ->
    ranges = []
    @editor.scanInBufferRange pattern, scanRange, ({range}) ->
      ranges.push(range)
    markers = highlightRanges @editor, ranges,
      invalidate: 'inside'
      class: 'vim-mode-plus-highlight-search'
    markers

  refreshHighlightSearch: ->
    [startRow, endRow] = @editorElement.getVisibleRowRange()
    return unless scanRange = getVisibleBufferRange(@editor)
    @clearHighlightSearch()
    return if matchScopes(@editorElement, settings.get('highlightSearchExcludeScopes'))

    if settings.get('highlightSearch') and @main.highlightSearchPattern?
      @highlightSearchMarkers = @highlightSearch(@main.highlightSearchPattern, scanRange)

  # Repeat
  # -------------------------
  reapatRecordedOperation: ->
    @operationStack.runRecorded()

  # rangeMarkers for narrowRange
  # -------------------------
  addRangeMarkers: (markers) ->
    @rangeMarkers.push(markers...)
    @updateHasRangeMarkerState()

  addRangeMarkersForRanges: (ranges) ->
    markers = highlightRanges(@editor, ranges, class: 'vim-mode-plus-range-marker')
    @addRangeMarkers(markers)

  removeRangeMarker: (rangeMarker) ->
    _.remove(@rangeMarkers, rangeMarker)
    @updateHasRangeMarkerState()

  getRangeMarkerAtBufferPosition: (point) ->
    exclusive = false
    for rangeMarker in @getRangeMarkers()
      if rangeMarker.getBufferRange().containsPoint(point, exclusive)
        return rangeMarker

  updateHasRangeMarkerState: ->
    @toggleClassList('with-range-marker', @hasRangeMarkers())

  hasRangeMarkers: ->
    @rangeMarkers.length > 0

  getRangeMarkers: (markers) ->
    @rangeMarkers

  getRangeMarkerBufferRanges: ({cursorContainedOnly}={}) ->
    ranges = @rangeMarkers.map (marker) ->
      marker.getBufferRange()

    unless (cursorContainedOnly ? false)
      ranges
    else
      points = @editor.getCursorBufferPositions()
      ranges.filter (range) ->
        isRangeContainsSomePoint(range, points, exclusive: false)

  eachRangeMarkers: (fn) ->
    for rangeMarker in @getRangeMarkers()
      fn(rangeMarker)

  clearRangeMarkers: ->
    @eachRangeMarkers (rangeMarker) ->
      rangeMarker.destroy()
    @rangeMarkers = []
    @toggleClassList('with-range-marker', @hasRangeMarkers())
