package app.laptrace.logger.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val Orange = Color(0xFFFF9500)
val Green = Color(0xFF34C759)
val Yellow = Color(0xFFFFCC00)
val Red = Color(0xFFFF3B30)
val Blue = Color(0xFF0A84FF)
val Secondary = Color(0xFF9A9AA0)
val Card = Color(0xFF1C1C1E)

private val scheme = darkColorScheme(
    primary = Orange,
    onPrimary = Color.Black,
    secondary = Orange,
    background = Color.Black,
    surface = Color.Black,
    surfaceVariant = Card,
    surfaceContainer = Card,
    surfaceContainerHigh = Color(0xFF2C2C2E),
    onBackground = Color.White,
    onSurface = Color.White,
    onSurfaceVariant = Secondary,
    error = Red,
)

@Composable
fun LaptraceTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = scheme, typography = Typography(), content = content)
}
