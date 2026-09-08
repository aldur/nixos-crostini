#include <gtk/gtk.h>
#include <stdio.h>

static GtkWidget *window;
static int status = 1;

static gboolean finish(gpointer unused) {
  gtk_main_quit();
  return FALSE;
}

static gboolean inspect(gpointer unused) {
  gchar *theme = NULL;
  g_object_get(gtk_settings_get_default(), "gtk-theme-name", &theme, NULL);
  // Adwaita uses its own base style and GTK's pixbuf engine for buttons.
  const char *engine = G_OBJECT_TYPE_NAME(gtk_widget_get_style(window));
  gboolean mapped = gdk_window_is_viewable(window->window);
  gint width, height;
  gdk_display_sync(gdk_display_get_default());
  gdk_drawable_get_size(window->window, &width, &height);
  GdkPixbuf *pixels = mapped ? gdk_pixbuf_get_from_drawable(NULL, window->window,
      gtk_widget_get_colormap(window), 0, 0, 0, 0, width, height) : NULL;
  status = !(g_strcmp0(theme, "Adwaita") == 0 &&
      g_strcmp0(engine, "AdwaitaStyle") == 0 && pixels != NULL);
  g_print("GTK2 theme=%s engine=%s mapped=%s rendered=%s size=%dx%d\n",
      theme, engine, mapped ? "yes" : "no", pixels ? "yes" : "no", width, height);
  if (pixels) g_object_unref(pixels);
  g_free(theme);
  if (status) {
    gtk_main_quit();
  } else {
    // Keep processing events while the host captures Weston's output.
    g_timeout_add_seconds(5, finish, NULL);
  }
  return FALSE;
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IOLBF, 0);
  gtk_init(&argc, &argv);
  window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gchar *title = g_strdup_printf("Baguette GTK2 %s", g_getenv("DISPLAY"));
  gtk_window_set_title(GTK_WINDOW(window), title);
  g_free(title);
  gtk_window_set_default_size(GTK_WINDOW(window), 460, 260);
  gtk_container_set_border_width(GTK_CONTAINER(window), 16);
  GtkWidget *box = gtk_vbox_new(FALSE, 12);
  gtk_container_add(GTK_CONTAINER(window), box);
  gtk_box_pack_start(GTK_BOX(box), gtk_label_new("GTK2 in the shipped Baguette image"), FALSE, FALSE, 0);
  GtkWidget *entry = gtk_entry_new();
  gtk_entry_set_text(GTK_ENTRY(entry), "Adwaita from nixpkgs");
  gtk_box_pack_start(GTK_BOX(box), entry, FALSE, FALSE, 0);
  GtkWidget *check = gtk_check_button_new_with_label("GTK2 controls render correctly");
  gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(check), TRUE);
  gtk_box_pack_start(GTK_BOX(box), check, FALSE, FALSE, 0);
  GtkWidget *progress = gtk_progress_bar_new();
  gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(progress), 0.65);
  gtk_box_pack_start(GTK_BOX(box), progress, FALSE, FALSE, 0);
  GtkWidget *button = gtk_button_new_with_label("Test button");
  gtk_box_pack_start(GTK_BOX(box), button, FALSE, FALSE, 0);
  gtk_widget_show_all(window);
  g_timeout_add(1000, inspect, NULL);
  gtk_main();
  gtk_widget_destroy(window);
  gdk_display_sync(gdk_display_get_default());
  return status;
}
