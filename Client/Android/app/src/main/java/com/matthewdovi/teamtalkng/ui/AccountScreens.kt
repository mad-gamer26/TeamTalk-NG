/*
 * The NG Account screens: signing up and in, the account (what syncs, devices,
 * password, export, signing out, deleting).
 */
package com.matthewdovi.teamtalkng.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.matthewdovi.teamtalkng.NGAccountCenter
import com.matthewdovi.teamtalkng.NGSession
import com.matthewdovi.teamtalkng.announce
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import android.text.format.DateUtils
import java.io.File

private sealed interface AccountForm {
    data object SignIn : AccountForm
    data object SignUp : AccountForm
    data class Verify(val email: String, val password: String) : AccountForm
    data object Forgot : AccountForm
    data class Reset(val email: String) : AccountForm
    data object ChangePassword : AccountForm
    data object DeleteAccount : AccountForm
}

private class FormField(val label: String, val secret: Boolean = false, val keyboard: KeyboardType = KeyboardType.Text)

@Composable
fun AccountScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    NGAccountCenter.revision.intValue
    val forms = remember { mutableStateListOf<AccountForm>() }
    var signingOut by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    val form = forms.lastOrNull()
    if (form != null) {
        androidx.activity.compose.BackHandler { forms.removeAt(forms.lastIndex) }
        AccountFormScreen(form, push = { forms.add(it) }, pop = { forms.removeAt(forms.lastIndex) }, finish = { forms.clear() })
        return
    }

    ScreenFrame("NG Account") {
        GroupedBody {
            if (NGAccountCenter.isSignedIn) {
                GroupedSection {
                    ValueRow("Email", NGAccountCenter.email.orEmpty())
                    RowDivider()
                    NavRow("Change Password") { forms.add(AccountForm.ChangePassword) }
                }
                GroupedSection(header = "Sync", footer = "What your NG Account keeps in step on every device you sign in on. Your monitors always belong to your account.") {
                    NGAccountCenter.Category.entries.forEach { c ->
                        ToggleRow(c.title, NGAccountCenter.isSyncing(c)) { NGAccountCenter.setSyncing(c, it) }
                    }
                }
                GroupedSection {
                    NavRow("Devices") { Navigator.push(Screen.AccountDevices) }
                    RowDivider()
                    TextRow("Export My Data", onClick = {
                        scope.launch {
                            runCatching {
                                val data = NGAccountCenter.signed { it.export() }
                                File(context.cacheDir, "NG Account.json").also { it.writeBytes(data) }
                            }.onSuccess { shareFile(context, it, "application/json") }.onFailure { error = it.message }
                        }
                    })
                }
                GroupedSection(footer = "Deleting your account removes your monitors, synced servers and settings, and backed-up sound packs. Packs you published stay in the catalog.") {
                    TextRow("Sign Out", color = MaterialTheme.colorScheme.error, onClick = { signingOut = true })
                    RowDivider()
                    TextRow("Delete Account", color = MaterialTheme.colorScheme.error, onClick = { forms.add(AccountForm.DeleteAccount) })
                }
            } else {
                val footer = "Monitors need an NG Account. It's optional for everything else: it keeps your servers, settings, sound packs and monitors in one place, so a new phone or reinstalling TeamTalk NG only needs signing in, and it lets you back up and publish sound packs."
                GroupedSection(footer = footer) {
                    NavRow("Sign In") { forms.add(AccountForm.SignIn) }
                    RowDivider()
                    NavRow("Create Account") { forms.add(AccountForm.SignUp) }
                }
            }
        }
    }
    if (signingOut) {
        ActionsDialog(
            "Sign Out of NG Account?",
            "Your monitors keep running; sign in again to see them.\n\nRemoving takes your synced servers, your backed-up sound packs and the packs you downloaded from the catalog off this phone. They're still in your account, and signing in again brings them back. Your settings stay as they are, and sound packs that haven't finished backing up stay too.",
            listOf(
                "Sign Out and Keep a Copy" to { scope.launch { NGAccountCenter.signOut(false) }; Unit },
                "Sign Out and Remove from This Phone" to { scope.launch { NGAccountCenter.signOut(true) }; Unit },
            ),
        ) { signingOut = false }
    }
    error?.let { MessageDialog("NG Account", it) { error = null } }
}

@Composable
private fun AccountFormScreen(kind: AccountForm, push: (AccountForm) -> Unit, pop: () -> Unit, finish: () -> Unit) {
    val scope = rememberCoroutineScope()
    val title = when (kind) {
        AccountForm.SignIn -> "Sign In"
        AccountForm.SignUp -> "Create Account"
        is AccountForm.Verify -> "Check Your Email"
        AccountForm.Forgot -> "Reset Password"
        is AccountForm.Reset -> "New Password"
        AccountForm.ChangePassword -> "Change Password"
        AccountForm.DeleteAccount -> "Delete Account"
    }
    val action = when (kind) {
        AccountForm.SignIn -> "Sign In"
        AccountForm.SignUp -> "Continue"
        is AccountForm.Verify -> "Finish"
        AccountForm.Forgot -> "Email Me a Code"
        is AccountForm.Reset, AccountForm.ChangePassword -> "Save"
        AccountForm.DeleteAccount -> "Delete"
    }
    val footer = when (kind) {
        AccountForm.SignUp -> "We'll email you a code to finish. Choose a password of at least 8 characters."
        is AccountForm.Verify -> "We emailed a 6-digit code to ${kind.email}. It works for 15 minutes."
        AccountForm.Forgot -> "We'll email you a code to choose a new password with."
        is AccountForm.Reset -> "Type the code we emailed to ${kind.email}, and choose a new password. Your other devices will be signed out."
        AccountForm.ChangePassword -> "Your other devices will be signed out."
        AccountForm.DeleteAccount -> "This deletes your NG Account for good: your monitors stop, and your synced servers, settings and backed-up sound packs are removed. Packs you published stay in the catalog. What's on this phone stays."
        AccountForm.SignIn -> null
    }
    val email = FormField("Email", keyboard = KeyboardType.Email)
    val code = FormField("Code", keyboard = KeyboardType.Number)
    val fields = when (kind) {
        AccountForm.SignIn -> listOf(email, FormField("Password", true))
        AccountForm.SignUp -> listOf(email, FormField("Password", true), FormField("Password Again", true))
        is AccountForm.Verify -> listOf(code)
        AccountForm.Forgot -> listOf(email)
        is AccountForm.Reset -> listOf(code, FormField("New Password", true), FormField("New Password Again", true))
        AccountForm.ChangePassword -> listOf(FormField("Current Password", true), FormField("New Password", true), FormField("New Password Again", true))
        AccountForm.DeleteAccount -> listOf(FormField("Password", true))
    }
    val values = remember(kind) { mutableStateListOf(*Array(fields.size) { "" }) }
    var message by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var whose by remember { mutableStateOf<CompletableDeferred<Boolean>?>(null) }

    fun trimmed(i: Int) = values[i].trim()

    suspend fun perform() {
        val center = NGAccountCenter
        center.askWhoseData = {
            val answer = CompletableDeferred<Boolean>()
            whose = answer
            answer.await()
        }
        when (kind) {
            AccountForm.SignIn -> { center.signIn(trimmed(0), values[1]); finish() }
            AccountForm.SignUp -> { center.signUp(trimmed(0), values[1]); push(AccountForm.Verify(trimmed(0), values[1])) }
            is AccountForm.Verify -> { center.verify(kind.email, trimmed(0)); finish() }
            AccountForm.Forgot -> { center.forgotPassword(trimmed(0)); push(AccountForm.Reset(trimmed(0))) }
            is AccountForm.Reset -> { center.resetPassword(kind.email, trimmed(0), values[1]); finish() }
            AccountForm.ChangePassword -> {
                center.signed { it.changePassword(values[0], values[1]) }
                announce("Password changed")
                pop()
            }
            AccountForm.DeleteAccount -> confirmDelete = true
        }
    }

    fun submit() {
        if (busy) return
        fields.forEachIndexed { i, f ->
            if (values[i].isEmpty()) {
                message = "Enter your ${f.label.lowercase()}."
                return
            }
        }
        if (kind == AccountForm.SignUp || kind == AccountForm.ChangePassword || kind is AccountForm.Reset) {
            if (values[fields.size - 1] != values[fields.size - 2]) {
                message = "The two passwords aren't the same."
                return
            }
        }
        busy = true
        scope.launch {
            try {
                perform()
            } catch (e: Exception) {
                message = e.message
            } finally {
                busy = false
            }
        }
    }

    ScreenFrame(title, onBack = pop) {
        GroupedBody {
            GroupedSection(footer = footer) {
                fields.forEachIndexed { i, f ->
                    OutlinedTextField(
                        value = values[i],
                        onValueChange = { values[i] = it },
                        label = { Text(f.label) },
                        singleLine = true,
                        visualTransformation = if (f.secret) PasswordVisualTransformation() else VisualTransformation.None,
                        keyboardOptions = KeyboardOptions(keyboardType = if (f.secret) KeyboardType.Password else f.keyboard, autoCorrectEnabled = false),
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                    )
                }
            }
            GroupedSection {
                TextRow(action, enabled = !busy,
                    color = if (kind == AccountForm.DeleteAccount) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
                    onClick = ::submit)
            }
            when (kind) {
                AccountForm.SignIn -> GroupedSection { TextRow("Forgot Password?", onClick = { push(AccountForm.Forgot) }) }
                is AccountForm.Verify -> GroupedSection {
                    TextRow("Email Me a New Code", onClick = {
                        scope.launch {
                            runCatching { NGAccountCenter.signUp(kind.email, kind.password) }
                                .onSuccess { announce("New code sent") }.onFailure { message = it.message }
                        }
                    })
                }
                is AccountForm.Reset -> GroupedSection {
                    TextRow("Email Me a New Code", onClick = {
                        scope.launch {
                            runCatching { NGAccountCenter.forgotPassword(kind.email) }
                                .onSuccess { announce("New code sent") }.onFailure { message = it.message }
                        }
                    })
                }
                else -> {}
            }
        }
    }
    message?.let { MessageDialog(title, it) { message = null } }
    if (confirmDelete) {
        ConfirmationDialog("Delete Your NG Account? This can't be undone.", "Delete Account", onConfirm = {
            scope.launch {
                runCatching { NGAccountCenter.deleteAccount(values[0]) }
                    .onSuccess { announce("NG Account deleted"); finish() }.onFailure { message = it.message }
            }
        }, onDismiss = { confirmDelete = false })
    }
    whose?.let { answer ->
        AlertDialog(
            onDismissRequest = {},
            title = { Text("Keep Which Servers and Settings?") },
            text = { Text("Your NG Account already has servers and settings, and so does this phone. Servers are combined either way. Choose whose settings to keep, and whose version of a server you have in both places.") },
            confirmButton = { TextButton(onClick = { whose = null; answer.complete(true) }) { Text("Keep This Phone's") } },
            dismissButton = { TextButton(onClick = { whose = null; answer.complete(false) }) { Text("Use My Account's") } },
        )
    }
}

@Composable
fun AccountDevicesScreen() {
    val scope = rememberCoroutineScope()
    var sessions by remember { mutableStateOf<List<NGSession>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        runCatching { NGAccountCenter.signed { it.sessions() } }.onSuccess { sessions = it }.onFailure { error = it.message }
    }
    ScreenFrame("Devices") {
        GroupedBody {
            GroupedSection(footer = "Swipe a device to sign it out.") {
                sessions.forEachIndexed { i, s ->
                    if (i > 0) RowDivider()
                    ActionRow(listOf(RowAction("Sign Out", destructive = true, swipe = true) {
                        scope.launch {
                            runCatching {
                                if (s.current) {
                                    NGAccountCenter.signOut(false)
                                    Navigator.pop()
                                } else {
                                    NGAccountCenter.signed { it.endSession(s.id) }
                                    sessions = sessions.filter { it.id != s.id }
                                }
                            }.onFailure { error = it.message }
                        }
                    })) {
                        Column(Modifier.fillMaxWidth().padding(RowPadding)) {
                            Text(if (s.current) "${s.name} (This Phone)" else s.name)
                            val now = System.currentTimeMillis()
                            val used = if (now - s.lastSeen < 60_000) "just now" else DateUtils.getRelativeTimeSpanString(s.lastSeen, now, 60_000)
                            Text("Last used $used", style = MaterialTheme.typography.bodySmall, color = secondaryText())
                        }
                    }
                }
            }
        }
    }
    error?.let { MessageDialog("NG Account", it) { error = null } }
}
