package com.matthewdovi.teamtalkng.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.semantics.semantics
import kotlinx.coroutines.withTimeoutOrNull
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.collapse
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.expand
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import kotlinx.coroutines.launch

val SystemBlue = Color(0xFF007AFF)
val SystemRed = Color(0xFFFF3B30)

@Composable
fun TeamTalkTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val colors = if (dark) {
        darkColorScheme(
            primary = Color(0xFF0A84FF),
            onPrimary = Color.White,
            error = Color(0xFFFF453A),
            surface = Color(0xFF1C1C1E),
            surfaceContainer = Color(0xFF1C1C1E),
            surfaceContainerHigh = Color(0xFF2C2C2E),
            background = Color.Black,
            onBackground = Color.White,
            secondaryContainer = Color(0xFF0A3A70),
            onSecondaryContainer = Color.White,
        )
    } else {
        lightColorScheme(
            primary = SystemBlue,
            onPrimary = Color.White,
            error = SystemRed,
            surface = Color.White,
            surfaceContainer = Color.White,
            surfaceContainerHigh = Color(0xFFF2F2F7),
            background = Color.White,
            onBackground = Color.Black,
            secondaryContainer = Color(0xFFD6E8FF),
            onSecondaryContainer = Color(0xFF00315F),
        )
    }
    MaterialTheme(colorScheme = colors, content = content)
}

/** The iOS app's soft blue-to-peach backdrop. */
@Composable
fun BackgroundGradient(modifier: Modifier = Modifier) {
    val colors = if (isSystemInDarkTheme()) {
        listOf(Color(0xFF0E1420), Color(0xFF101B2B), Color(0xFF1E1712))
    } else {
        listOf(Color(0xFFF2F7FC), Color(0xFFE0EBF5), Color(0xFFFAF0E6))
    }
    Box(modifier.fillMaxSize().background(Brush.linearGradient(colors)))
}

val CardShape = RoundedCornerShape(14.dp)

@Composable
fun cardColor(): Color = MaterialTheme.colorScheme.surface

@Composable
fun secondaryText(): Color = MaterialTheme.colorScheme.onSurfaceVariant

/** A rounded group of rows, like a section of an iOS inset-grouped list. */
@Composable
fun GroupedSection(
    modifier: Modifier = Modifier,
    header: String? = null,
    footer: String? = null,
    color: Color = cardColor(),
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(modifier.fillMaxWidth()) {
        if (header != null) SectionHeader(header)
        Surface(shape = CardShape, color = color, modifier = Modifier.fillMaxWidth()) {
            Column(content = content)
        }
        if (footer != null) {
            Text(
                footer,
                style = MaterialTheme.typography.bodySmall,
                color = secondaryText(),
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
            )
        }
    }
}

@Composable
fun SectionHeader(text: String) {
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelMedium,
        color = secondaryText(),
        modifier = Modifier
            .padding(start = 16.dp, end = 16.dp, bottom = 6.dp)
            .semantics { heading() },
    )
}

@Composable
fun RowDivider() {
    HorizontalDivider(Modifier.padding(start = 16.dp), color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
}

/** Shape for item [index] of [count] rows drawn as one rounded group in a lazy list. */
fun groupedItemShape(index: Int, count: Int): Shape {
    val r = 14.dp
    return when {
        count == 1 -> RoundedCornerShape(r)
        index == 0 -> RoundedCornerShape(topStart = r, topEnd = r)
        index == count - 1 -> RoundedCornerShape(bottomStart = r, bottomEnd = r)
        else -> RoundedCornerShape(0.dp)
    }
}

val RowPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp)

/** A plain tappable row of text, like a Button inside an iOS List. */
@Composable
fun TextRow(
    text: String,
    modifier: Modifier = Modifier,
    horizontalPadding: Dp = 16.dp,
    color: Color = MaterialTheme.colorScheme.primary,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .combinedClickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = horizontalPadding, vertical = 12.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        Text(text, color = if (enabled) color else color.copy(alpha = 0.38f), style = MaterialTheme.typography.bodyLarge)
    }
}

/** The iOS app's "Show Password" toggle row. */
@Composable
fun SwitchRow(label: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .toggleable(value = checked, role = Role.Switch, onValueChange = onCheckedChange)
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = null)
    }
}

/** The full-width blue button the iOS app uses for its main actions. */
@Composable
fun ActionButton(
    title: String,
    busy: Boolean,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Button(
        onClick = onClick,
        enabled = enabled && !busy,
        shape = RoundedCornerShape(14.dp),
        colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
        contentPadding = PaddingValues(vertical = 14.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        Text(title)
        if (busy) {
            Spacer(Modifier.width(8.dp))
            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = MaterialTheme.colorScheme.onPrimary)
        }
    }
}

/** Error or status text that TalkBack reads as soon as it appears. */
@Composable
fun AnnouncedText(text: String, color: Color, modifier: Modifier = Modifier, textAlign: TextAlign? = null) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = color,
        textAlign = textAlign,
        modifier = modifier.semantics { liveRegion = LiveRegionMode.Polite },
    )
}

/**
 * A long press for fingers only. Rows offer their actions to TalkBack as custom
 * actions; a long click would add a "Show actions" entry repeating them.
 */
fun Modifier.longPressOnly(onLongPress: () -> Unit): Modifier = pointerInput(onLongPress) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
        var ended = false
        withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
            while (!ended) {
                val change = awaitPointerEvent(PointerEventPass.Initial).changes.firstOrNull { it.id == down.id } ?: break
                val moved = (change.position - down.position).getDistance() > viewConfiguration.touchSlop
                if (!change.pressed || moved) ended = true
            }
        }
        if (!ended) {
            onLongPress()
            // The finger coming up is not also a tap.
            do {
                val event = awaitPointerEvent(PointerEventPass.Initial)
                event.changes.forEach { it.consume() }
            } while (event.changes.any { it.pressed })
        }
    }
}

/** A tick for sighted users: the row's state already says it to TalkBack. */
@Composable
fun SelectedTick() {
    Text("✓", color = MaterialTheme.colorScheme.primary, modifier = Modifier.clearAndSetSemantics {})
}

/** An action offered on a row: by swiping (when [swipe] is set), long-pressing, and from TalkBack's actions menu. */
class RowAction(val label: String, val destructive: Boolean = false, val swipe: Boolean = false, val perform: () -> Unit)

/**
 * A list row with the actions iOS puts behind a swipe. Swiping toward the
 * start runs the row's swipe action; every action is also in a long-press
 * menu and in TalkBack's actions.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ActionRow(
    actions: List<RowAction>,
    modifier: Modifier = Modifier,
    background: Color = cardColor(),
    shape: Shape = RoundedCornerShape(0.dp),
    onClick: (() -> Unit)? = null,
    onClickLabel: String? = null,
    selected: Boolean? = null,
    content: @Composable () -> Unit,
) {
    var menuExpanded by remember { mutableStateOf(false) }
    val swipeAction = actions.firstOrNull { it.swipe }
    val scope = rememberCoroutineScope()
    val dismissState = rememberSwipeToDismissBoxState()

    val rowModifier = Modifier
        .fillMaxWidth()
        .background(background, shape)
        .clickable(
            onClick = { onClick?.invoke() },
            onClickLabel = onClickLabel,
            role = if (selected != null) Role.RadioButton else if (onClick != null) Role.Button else null,
        )
        .then(if (actions.isNotEmpty()) Modifier.longPressOnly { menuExpanded = true } else Modifier)
        .semantics {
            customActions = actions.map { action -> CustomAccessibilityAction(action.label) { action.perform(); true } }
            if (selected != null) {
                stateDescription = if (selected) "Selected" else "Not selected"
            }
        }

    val body: @Composable () -> Unit = {
        Box(rowModifier) {
            content()
            DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                actions.forEach { action ->
                    DropdownMenuItem(
                        text = {
                            Text(action.label, color = if (action.destructive) MaterialTheme.colorScheme.error else Color.Unspecified)
                        },
                        onClick = {
                            menuExpanded = false
                            action.perform()
                        },
                    )
                }
            }
        }
    }

    if (swipeAction == null) {
        Box(modifier) { body() }
        return
    }
    SwipeToDismissBox(
        state = dismissState,
        modifier = modifier,
        enableDismissFromStartToEnd = false,
        onDismiss = { value ->
            if (value == SwipeToDismissBoxValue.EndToStart) swipeAction.perform()
            scope.launch { dismissState.reset() }
        },
        backgroundContent = {
            val color = if (swipeAction.destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary
            Box(
                Modifier.fillMaxSize().background(color, shape).padding(horizontal = 20.dp),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Text(swipeAction.label, color = Color.White, fontWeight = FontWeight.SemiBold)
            }
        },
    ) { body() }
}

/** A confirmation like the iOS app's confirmation dialogs: a destructive button and Cancel. */
@Composable
fun ConfirmationDialog(
    title: String,
    confirmLabel: String,
    destructive: Boolean = true,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        text = { Text(title, style = MaterialTheme.typography.bodyLarge) },
        confirmButton = {
            TextButton(onClick = { onDismiss(); onConfirm() }) {
                Text(confirmLabel, color = if (destructive) MaterialTheme.colorScheme.error else Color.Unspecified)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** A collapsible section, like SwiftUI's DisclosureGroup. */
@Composable
fun DisclosureSection(
    title: String,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    GroupedSection {
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 52.dp)
                .clickable(role = Role.Button) { onExpandedChange(!expanded) }
                .semantics {
                    heading()
                    if (expanded) collapse { onExpandedChange(false); true } else expand { onExpandedChange(true); true }
                }
                .padding(RowPadding),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Icon(
                if (expanded) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
            )
        }
        if (expanded) {
            RowDivider()
            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                content()
            }
        }
    }
}

/** A heading-less line of label and value, like an iOS value1 row. */
@Composable
fun ValueRow(label: String, value: String, onClick: (() -> Unit)? = null) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .semantics(mergeDescendants = true) {}
            .padding(RowPadding),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, style = MaterialTheme.typography.bodyLarge)
        Spacer(Modifier.width(12.dp))
        Text(value, style = MaterialTheme.typography.bodyMedium, color = secondaryText(), textAlign = TextAlign.End)
    }
}

/** A row that opens another screen. */
@Composable
fun NavRow(label: String, value: String? = null, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) {}
            .padding(RowPadding),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        if (value != null) {
            Text(value, style = MaterialTheme.typography.bodyMedium, color = secondaryText())
        }
    }
}

/** A switch in a grouped section, with the section's padding. */
@Composable
fun ToggleRow(label: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    SwitchRow(label, checked, onCheckedChange, Modifier.padding(horizontal = 16.dp))
}

/** A percent slider moving in tens, like the iPhone app's volume sliders. */
@Composable
fun PercentSlider(label: String, percent: Int, onChange: (Int) -> Unit) {
    SliderRow(label, percent.toFloat(), 0f, 100f, 9, "$percent %") { onChange((it / 10).toInt() * 10) }
}

@Composable
fun SliderRow(label: String, value: Float, min: Float, max: Float, steps: Int, valueText: String, onChange: (Float) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)) {
        Row(Modifier.fillMaxWidth().clearAndSetSemantics {}, horizontalArrangement = Arrangement.SpaceBetween) {
            Text(label, style = MaterialTheme.typography.bodyLarge)
            Text(valueText, style = MaterialTheme.typography.bodyMedium, color = secondaryText())
        }
        androidx.compose.material3.Slider(
            value = value,
            onValueChange = onChange,
            valueRange = min..max,
            steps = steps,
            // TalkBack speaks only a slider's state, so its name goes there.
            modifier = Modifier.semantics { stateDescription = "$label, $valueText" },
        )
    }
}

/** One of several options, as radio rows (the iPhone app's segmented controls). */
@Composable
fun <T> ChoiceRow(label: String, options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp).selectableGroup()) {
        Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.semantics { heading() })
        options.forEach { (value, title) ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = 44.dp)
                    .selectable(selected = value == selected, role = Role.RadioButton, onClick = { onSelect(value) }),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                androidx.compose.material3.RadioButton(selected = value == selected, onClick = null)
                Spacer(Modifier.width(10.dp))
                Text(title, style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

/** Plus and minus for a number, like an iOS stepper. */
@Composable
fun StepperRow(label: String, value: Int, min: Int, max: Int, step: Int, unit: String, onChange: (Int) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .clearAndSetSemantics {
                contentDescription = "$label, $value $unit"
                customActions = listOf(
                    CustomAccessibilityAction("Increase") { if (value + step <= max) { onChange(value + step); true } else false },
                    CustomAccessibilityAction("Decrease") { if (value - step >= min) { onChange(value - step); true } else false },
                )
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(label, style = MaterialTheme.typography.bodyLarge)
            Text("$value $unit", style = MaterialTheme.typography.bodySmall, color = secondaryText())
        }
        // TalkBack has these as the row's Increase and Decrease actions.
        TextButton(enabled = value - step >= min, onClick = { onChange(value - step) }, modifier = Modifier.clearAndSetSemantics {}) { Text("−") }
        TextButton(enabled = value + step <= max, onClick = { onChange(value + step) }, modifier = Modifier.clearAndSetSemantics {}) { Text("+") }
    }
}

/** A dialog with one line to fill in, like an alert with a text field. */
@Composable
fun TextEntryDialog(
    title: String,
    label: String,
    confirm: String,
    initial: String = "",
    message: String? = null,
    secret: Boolean = false,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (message != null) Text(message, style = MaterialTheme.typography.bodyMedium)
                androidx.compose.material3.OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    label = { Text(label) },
                    singleLine = true,
                    visualTransformation = if (secret) androidx.compose.ui.text.input.PasswordVisualTransformation()
                    else androidx.compose.ui.text.input.VisualTransformation.None,
                )
            }
        },
        confirmButton = { TextButton(onClick = { onDismiss(); onConfirm(text) }) { Text(confirm) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
fun MessageDialog(title: String, message: String, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = { TextButton(onClick = onDismiss) { Text("OK") } },
    )
}

/** A choice of actions, the iPhone app's action sheets. */
@Composable
fun ActionsDialog(title: String, message: String? = null, actions: List<Pair<String, () -> Unit>>, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column {
                if (message != null) Text(message, style = MaterialTheme.typography.bodyMedium)
                actions.forEach { (label, perform) ->
                    TextButton(onClick = { onDismiss(); perform() }, modifier = Modifier.fillMaxWidth()) { Text(label) }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
