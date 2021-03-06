BrowserWindow = null # Defer require until actually used
RendererIpc = require 'ipc'

{$, View} = require 'atom-space-pen-views'
{CompositeDisposable} = require 'atom'
_ = require 'underscore-plus'
TabView = require './tab-view'

module.exports =
class TabBarView extends View
  @content: ->
    @ul tabindex: -1, class: "list-inline tab-bar inset-panel"

  initialize: (@pane, state={}) ->
    @subscriptions = new CompositeDisposable

    @subscriptions.add atom.commands.add atom.views.getView(@pane),
      'tabs:keep-preview-tab': => @clearPreviewTabs()
      'tabs:close-tab': => @closeTab(@getActiveTab())
      'tabs:close-other-tabs': => @closeOtherTabs(@getActiveTab())
      'tabs:close-tabs-to-right': => @closeTabsToRight(@getActiveTab())
      'tabs:close-saved-tabs': => @closeSavedTabs()
      'tabs:close-all-tabs': => @closeAllTabs()

    addElementCommands = (commands) =>
      commandsWithPropagationStopped = {}
      Object.keys(commands).forEach (name) ->
        commandsWithPropagationStopped[name] = (event) ->
          event.stopPropagation()
          commands[name]()

      @subscriptions.add(atom.commands.add(@element, commandsWithPropagationStopped))

    addElementCommands
      'tabs:close-tab': => @closeTab()
      'tabs:close-other-tabs': => @closeOtherTabs()
      'tabs:close-tabs-to-right': => @closeTabsToRight()
      'tabs:close-saved-tabs': => @closeSavedTabs()
      'tabs:close-all-tabs': => @closeAllTabs()
      'tabs:split-up': => @splitTab('splitUp')
      'tabs:split-down': => @splitTab('splitDown')
      'tabs:split-left': => @splitTab('splitLeft')
      'tabs:split-right': => @splitTab('splitRight')
      'tabs:open-in-new-window': => @onOpenInNewWindow()

    @on 'dragstart', '.sortable', @onDragStart
    @on 'dragend', '.sortable', @onDragEnd
    @on 'dragleave', @onDragLeave
    @on 'dragover', @onDragOver
    @on 'drop', @onDrop

    @paneContainer = @pane.getContainer()
    @addTabForItem(item) for item in @pane.getItems()
    @setInitialPreviewTab(state.previewTabURI)

    @subscriptions.add @pane.onDidDestroy =>
      @unsubscribe()

    @subscriptions.add @pane.onDidAddItem ({item, index}) =>
      @addTabForItem(item, index)

    @subscriptions.add @pane.onDidMoveItem ({item, newIndex}) =>
      @moveItemTabToIndex(item, newIndex)

    @subscriptions.add @pane.onDidRemoveItem ({item}) =>
      @removeTabForItem(item)

    @subscriptions.add @pane.onDidChangeActiveItem (item) =>
      @destroyPreviousPreviewTab()
      @updateActiveTab()

    @subscriptions.add atom.config.observe 'tabs.tabScrolling', => @updateTabScrolling()
    @subscriptions.add atom.config.observe 'tabs.tabScrollingThreshold', => @updateTabScrollingThreshold()
    @subscriptions.add atom.config.observe 'tabs.alwaysShowTabBar', => @updateTabBarVisibility()

    @handleTreeViewEvents()

    @updateActiveTab()

    @on 'mousedown', '.tab', ({target, which, ctrlKey}) =>
      tab = $(target).closest('.tab')[0]
      if which is 3 or (which is 1 and ctrlKey is true)
        @find('.right-clicked').removeClass('right-clicked')
        tab.classList.add('right-clicked')
        false
      else if which is 1 and not target.classList.contains('close-icon')
        @pane.activateItem(tab.item)
        setImmediate => @pane.activate()
        true
      else if which is 2
        @pane.destroyItem(tab.item)
        false

    @on 'dblclick', ({target}) =>
      if target is @element
        atom.commands.dispatch(@element, 'application:new-file')
        false

    @on 'click', '.tab .close-icon', ({target}) =>
      tab = $(target).closest('.tab')[0]
      @pane.destroyItem(tab.item)
      false

    RendererIpc.on('tab:dropped', @onDropOnOtherWindow)
    RendererIpc.on('tab:new-window-opened', @onNewWindowOpened)

  unsubscribe: ->
    RendererIpc.removeListener('tab:dropped', @onDropOnOtherWindow)
    RendererIpc.removeListener('tab:new-window-opened', @onNewWindowOpened)

    @subscriptions.dispose()

  handleTreeViewEvents: ->
    treeViewSelector = '.tree-view li[is=tree-view-file]'
    clearPreviewTabForFile = ({target}) =>
      return unless @pane.isFocused()

      target = target.querySelector('[data-path]') unless target.dataset.path

      if itemPath = target.dataset.path
        @tabForItem(@pane.itemForURI(itemPath))?.clearPreview()

    $(document.body).on('dblclick', treeViewSelector, clearPreviewTabForFile)
    @subscriptions.add dispose: ->
      $(document.body).off('dblclick', treeViewSelector, clearPreviewTabForFile)

  setInitialPreviewTab: (previewTabURI) ->
    for tab in @getTabs() when tab.isPreviewTab
      tab.clearPreview() if tab.item.getURI() isnt previewTabURI
    return

  getPreviewTabURI: ->
    for tab in @getTabs() when tab.isPreviewTab
      return tab.item.getURI()
    return

  clearPreviewTabs: ->
    tab.clearPreview() for tab in @getTabs()
    return

  storePreviewTabToDestroy: ->
    for tab in @getTabs() when tab.isPreviewTab
      @previewTabToDestroy = tab
    return

  destroyPreviousPreviewTab: ->
    if @previewTabToDestroy?.isPreviewTab
      @pane.destroyItem(@previewTabToDestroy.item)
    @previewTabToDestroy = null

  addTabForItem: (item, index) ->
    tabView = new TabView()
    tabView.initialize(item)
    tabView.clearPreview() if @isItemMovingBetweenPanes
    @storePreviewTabToDestroy() if tabView.isPreviewTab
    @insertTabAtIndex(tabView, index)

  moveItemTabToIndex: (item, index) ->
    if tab = @tabForItem(item)
      tab.remove()
      @insertTabAtIndex(tab, index)

  insertTabAtIndex: (tab, index) ->
    followingTab = @tabAtIndex(index) if index?
    if followingTab
      @element.insertBefore(tab, followingTab)
    else
      @element.appendChild(tab)
    tab.updateTitle()
    @updateTabBarVisibility()

  removeTabForItem: (item) ->
    @tabForItem(item)?.destroy()
    tab.updateTitle() for tab in @getTabs()
    @updateTabBarVisibility()

  updateTabBarVisibility: ->
    if not atom.config.get('tabs.alwaysShowTabBar') and not @shouldAllowDrag()
      @element.classList.add('hidden')
    else
      @element.classList.remove('hidden')

  getTabs: ->
    @children('.tab').toArray()

  tabAtIndex: (index) ->
    @children(".tab:eq(#{index})")[0]

  tabForItem: (item) ->
    _.detect @getTabs(), (tab) -> tab.item is item

  setActiveTab: (tabView) ->
    if tabView? and not tabView.classList.contains('active')
      @element.querySelector('.tab.active')?.classList.remove('active')
      tabView.classList.add('active')

  getActiveTab: ->
    @tabForItem(@pane.getActiveItem())

  updateActiveTab: ->
    @setActiveTab(@tabForItem(@pane.getActiveItem()))

  closeTab: (tab) ->
    tab ?= @children('.right-clicked')[0]
    @pane.destroyItem(tab.item) if tab?

  splitTab: (fn) ->
    if item = @children('.right-clicked')[0]?.item
      if copiedItem = @copyItem(item)
        @pane[fn](items: [copiedItem])

  copyItem: (item) ->
    item.copy?() ? atom.deserializers.deserialize(item.serialize())

  closeOtherTabs: (active) ->
    tabs = @getTabs()
    active ?= @children('.right-clicked')[0]
    return unless active?
    @closeTab tab for tab in tabs when tab isnt active

  closeTabsToRight: (active) ->
    tabs = @getTabs()
    active ?= @children('.right-clicked')[0]
    index = tabs.indexOf(active)
    return if index is -1
    @closeTab tab for tab, i in tabs when i > index

  closeSavedTabs: ->
    for tab in @getTabs()
      @closeTab(tab) unless tab.item.isModified?()

  closeAllTabs: ->
    @closeTab(tab) for tab in @getTabs()

  getWindowId: ->
    @windowId ?= atom.getCurrentWindow().id

  shouldAllowDrag: ->
    (@paneContainer.getPanes().length > 1) or (@pane.getItems().length > 1)

  onDragStart: (event) =>
    event.originalEvent.dataTransfer.setData 'atom-event', 'true'

    element = $(event.target).closest('.sortable')
    element.addClass 'is-dragging'
    element[0].destroyTooltip()

    event.originalEvent.dataTransfer.setData 'sortable-index', element.index()

    paneIndex = @paneContainer.getPanes().indexOf(@pane)
    event.originalEvent.dataTransfer.setData 'from-pane-index', paneIndex
    event.originalEvent.dataTransfer.setData 'from-pane-id', @pane.id
    event.originalEvent.dataTransfer.setData 'from-window-id', @getWindowId()

    item = @pane.getItems()[element.index()]
    return unless item?

    itemURI = @getItemURI item

    if itemURI?
      event.originalEvent.dataTransfer.setData 'text/plain', itemURI

      if process.platform is 'darwin' # see #69
        itemURI = "file://#{itemURI}" unless @uriHasProtocol(itemURI)
        event.originalEvent.dataTransfer.setData 'text/uri-list', itemURI

      if item.isModified?() and item.getText?
        event.originalEvent.dataTransfer.setData 'has-unsaved-changes', 'true'
        event.originalEvent.dataTransfer.setData 'modified-text', item.getText()

  getItemURI: (item) ->
    return unless item?
    if typeof item.getURI is 'function'
      itemURI = item.getURI() ? ''
    else if typeof item.getPath is 'function'
      itemURI = item.getPath() ? ''
    else if typeof item.getUri is 'function'
      itemURI = item.getUri() ? ''

  onNewWindowOpened: (title, openURI, hasUnsavedChanges, modifiedText, scrollTop, fromWindowId) =>
    #remove any panes created by opening the window
    for item in @pane.getItems()
      @pane.destroyItem(item)

    # open the content and reset state based on previous state
    atom.workspace.open(openURI).then (item) ->
      item.setText?(modifiedText) if hasUnsavedChanges
      item.setScrollTop?(scrollTop)

    atom.focus()

    browserWindow = @browserWindowForId(fromWindowId)
    browserWindow?.webContents.send('tab:item-moved-to-window')

  onOpenInNewWindow: (active) =>
    tabs = @getTabs()
    active ?= @children('.right-clicked')[0]
    @openTabInNewWindow(active, window.screenX + 20, window.screenY + 20)

  openTabInNewWindow: (tab, windowX=0, windowY=0) =>
    item = @pane.getItems()[$(tab).index()]
    itemURI = @getItemURI(item)
    return unless itemURI?

    # open and then find the new window
    atom.commands.dispatch(@element, 'application:new-window')
    BrowserWindow ?= require('remote').require('browser-window')
    windows = BrowserWindow.getAllWindows()
    newWindow = windows[windows.length - 1]

    # move the tab to the new window
    newWindow.webContents.once 'did-finish-load', =>
      @moveAndSizeNewWindow(newWindow, windowX, windowY)
      itemScrollTop = item.getScrollTop?() ? 0
      hasUnsavedChanges = item.isModified?() ? false
      itemText = if hasUnsavedChanges then item.getText()  else ""

      #tell the new window to open this item and pass the current item state
      newWindow.send('tab:new-window-opened',
        item.getTitle(), itemURI, hasUnsavedChanges,
        itemText, itemScrollTop, @getWindowId())

      #listen for open success, so old tab can be removed
      RendererIpc.on('tab:item-moved-to-window', => @onTabMovedToWindow(item))

  onTabMovedToWindow: (item) ->
    # clear changes so moved item can be closed without a warning
    item.getBuffer?().reload()
    @pane.destroyItem(item)
    RendererIpc.removeListener('tab:item-moved-to-window', @onTabMovedToWindow)

  moveAndSizeNewWindow: (newWindow, windowX=0, windowY=0) ->
    WINDOW_MIN_WIDTH_HEIGHT = 300
    windowWidth = Math.min(window.innerWidth, window.screen.availWidth - windowX)
    windowHeight =  Math.min(window.innerHeight, window.screen.availHeight - windowY)
    if windowWidth < WINDOW_MIN_WIDTH_HEIGHT
      windowWidth = WINDOW_MIN_WIDTH_HEIGHT
      windowX = window.screen.availWidth - WINDOW_MIN_WIDTH_HEIGHT

    if windowHeight < WINDOW_MIN_WIDTH_HEIGHT
      windowHeight = WINDOW_MIN_WIDTH_HEIGHT
      windowY = window.screen.availHeight - WINDOW_MIN_WIDTH_HEIGHT

    newWindow.setPosition(windowX, windowY)
    newWindow.setSize(windowWidth, windowHeight)

  uriHasProtocol: (uri) ->
    try
      require('url').parse(uri).protocol?
    catch error
      false

  onDragLeave: (event) =>
    @removePlaceholder()

  onDragEnd: (event) =>
    {dataTransfer, screenX, screenY} = event.originalEvent

    #if the drop target doesn't handle the drop then this is a new window
    if dataTransfer.dropEffect is "none"
      @openTabInNewWindow(event.target, screenX, screenY)

    @clearDropTarget()

  onDragOver: (event) =>
    unless event.originalEvent.dataTransfer.getData('atom-event') is 'true'
      event.preventDefault()
      event.stopPropagation()
      return

    event.preventDefault()
    newDropTargetIndex = @getDropTargetIndex(event)
    return unless newDropTargetIndex?

    @removeDropTargetClasses()

    tabBar = @getTabBar(event.target)
    sortableObjects = tabBar.find(".sortable")

    if newDropTargetIndex < sortableObjects.length
      element = sortableObjects.eq(newDropTargetIndex).addClass 'is-drop-target'
      @getPlaceholder().insertBefore(element)
    else
      element = sortableObjects.eq(newDropTargetIndex - 1).addClass 'drop-target-is-after'
      @getPlaceholder().insertAfter(element)

  onDropOnOtherWindow: (fromPaneId, fromItemIndex) =>
    if @pane.id is fromPaneId
      if itemToRemove = @pane.getItems()[fromItemIndex]
        @pane.destroyItem(itemToRemove)

    @clearDropTarget()

  clearDropTarget: ->
    element = @find(".is-dragging")
    element.removeClass 'is-dragging'
    element[0]?.updateTooltip()
    @removeDropTargetClasses()
    @removePlaceholder()

  onDrop: (event) =>
    event.preventDefault()
    {dataTransfer} = event.originalEvent

    return unless dataTransfer.getData('atom-event') is 'true'

    fromWindowId  = parseInt(dataTransfer.getData('from-window-id'))
    fromPaneId    = parseInt(dataTransfer.getData('from-pane-id'))
    fromIndex     = parseInt(dataTransfer.getData('sortable-index'))
    fromPaneIndex = parseInt(dataTransfer.getData('from-pane-index'))

    hasUnsavedChanges = dataTransfer.getData('has-unsaved-changes') is 'true'
    modifiedText = dataTransfer.getData('modified-text')

    toIndex = @getDropTargetIndex(event)
    toPane = @pane

    @clearDropTarget()

    if fromWindowId is @getWindowId()
      fromPane = @paneContainer.getPanes()[fromPaneIndex]
      item = fromPane.getItems()[fromIndex]
      @moveItemBetweenPanes(fromPane, fromIndex, toPane, toIndex, item) if item?
    else
      droppedURI = dataTransfer.getData('text/plain')
      atom.workspace.open(droppedURI).then (item) =>
        # Move the item from the pane it was opened on to the target pane
        # where it was dropped onto
        activePane = atom.workspace.getActivePane()
        activeItemIndex = activePane.getItems().indexOf(item)
        @moveItemBetweenPanes(activePane, activeItemIndex, toPane, toIndex, item)
        item.setText?(modifiedText) if hasUnsavedChanges

        if not isNaN(fromWindowId)
          # Let the window where the drag started know that the tab was dropped
          browserWindow = @browserWindowForId(fromWindowId)
          browserWindow?.webContents.send('tab:dropped', fromPaneId, fromIndex)

      atom.focus()

  onMouseWheel: ({originalEvent}) =>
    return if originalEvent.shiftKey

    @wheelDelta ?= 0
    @wheelDelta += originalEvent.wheelDelta

    if @wheelDelta <= -@tabScrollingThreshold
      @wheelDelta = 0
      @pane.activateNextItem()
    else if @wheelDelta >= @tabScrollingThreshold
      @wheelDelta = 0
      @pane.activatePreviousItem()

  updateTabScrollingThreshold: ->
    @tabScrollingThreshold = atom.config.get('tabs.tabScrollingThreshold')

  updateTabScrolling: ->
    @tabScrolling = atom.config.get('tabs.tabScrolling')
    @tabScrollingThreshold = atom.config.get('tabs.tabScrollingThreshold')
    if @tabScrolling
      @on 'wheel', @onMouseWheel
    else
      @off 'wheel'

  browserWindowForId: (id) ->
    BrowserWindow ?= require('remote').require('browser-window')
    BrowserWindow.fromId id

  moveItemBetweenPanes: (fromPane, fromIndex, toPane, toIndex, item) ->
    try
      if toPane is fromPane
        toIndex-- if fromIndex < toIndex
        toPane.moveItem(item, toIndex)
      else
        @isItemMovingBetweenPanes = true
        fromPane.moveItemToPane(item, toPane, toIndex--)
      toPane.activateItem(item)
      toPane.activate()
    finally
      @isItemMovingBetweenPanes = false

  removeDropTargetClasses: ->
    workspaceElement = $(atom.views.getView(atom.workspace))
    workspaceElement.find('.tab-bar .is-drop-target').removeClass 'is-drop-target'
    workspaceElement.find('.tab-bar .drop-target-is-after').removeClass 'drop-target-is-after'

  getDropTargetIndex: (event) ->
    target = $(event.target)
    tabBar = @getTabBar(event.target)

    return if @isPlaceholder(target)

    sortables = tabBar.find('.sortable')
    element = target.closest('.sortable')
    element = sortables.last() if element.length is 0

    return 0 unless element.length

    elementCenter = element.offset().left + element.width() / 2

    if event.originalEvent.pageX < elementCenter
      sortables.index(element)
    else if element.next('.sortable').length > 0
      sortables.index(element.next('.sortable'))
    else
      sortables.index(element) + 1

  getPlaceholder: ->
    @placeholderEl ?= $('<li/>', class: 'placeholder')

  removePlaceholder: ->
    @placeholderEl?.remove()
    @placeholderEl = null

  isPlaceholder: (element) ->
    element.is('.placeholder')

  getTabBar: (target) ->
    target = $(target)
    if target.is('.tab-bar') then target else target.parents('.tab-bar')
