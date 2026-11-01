/*
 * A build without AudioNet's engine (see README.md): the toolbar has no
 * AudioNet button.
 */
package com.matthewdovi.teamtalkng

import android.content.Context
import androidx.compose.runtime.Composable

object AudioNetBridge {
    fun attach(context: Context) {}
    fun stopSending() {}
}

@Composable
fun AudioNetContent(session: ServerSession) {}
