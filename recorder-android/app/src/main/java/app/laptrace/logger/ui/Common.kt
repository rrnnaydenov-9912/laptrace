package app.laptrace.logger.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** A grouped list section like the iOS inset-grouped style. */
@Composable
fun Section(title: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        if (title != null) {
            Text(title.uppercase(), color = Secondary, fontSize = 12.sp, modifier = Modifier.padding(start = 16.dp, bottom = 6.dp))
        }
        Column(
            Modifier.fillMaxWidth().background(Card, RoundedCornerShape(12.dp)).padding(vertical = 4.dp),
            content = content,
        )
        if (footer != null) {
            Text(footer, color = Secondary, fontSize = 12.sp, modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 6.dp))
        }
    }
}

@Composable
fun KeyValue(key: String, value: String, valueColor: Color = Secondary, bold: Boolean = false) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 11.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(key, style = MaterialTheme.typography.bodyLarge)
        Text(value, color = valueColor, fontWeight = if (bold) FontWeight.Bold else null, style = MaterialTheme.typography.bodyLarge)
    }
}

@Composable
fun RowDivider() = HorizontalDivider(Modifier.padding(start = 16.dp), color = Color(0xFF38383A), thickness = 0.5.dp)

@Composable
fun ScreenTitle(text: String) {
    Text(text, fontSize = 32.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 20.dp, top = 12.dp, bottom = 4.dp))
}
