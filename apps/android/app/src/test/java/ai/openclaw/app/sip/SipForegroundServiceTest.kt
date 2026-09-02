package ai.openclaw.app.sip

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SipForegroundServiceTest {
  @Test
  fun sipServiceShouldStop_onlyWhenIdleOrFailedWithoutCall() {
    assertTrue(sipServiceShouldStop(SipState()))
    assertTrue(sipServiceShouldStop(SipState(status = SipRegistrationStatus.Failed)))
    assertFalse(sipServiceShouldStop(SipState(status = SipRegistrationStatus.Registered)))
    assertFalse(sipServiceShouldStop(SipState(status = SipRegistrationStatus.Registering)))
    assertFalse(sipServiceShouldStop(SipState(status = SipRegistrationStatus.Loading)))
    assertFalse(
      sipServiceShouldStop(
        SipState(status = SipRegistrationStatus.Failed, callStatus = SipCallStatus.Active),
      ),
    )
  }

  @Test
  fun sipNotificationTitle_prefersCallStateOverRegistration() {
    assertEquals(
      "Chiamata in arrivo",
      sipNotificationTitle(SipState(status = SipRegistrationStatus.Registered, callStatus = SipCallStatus.Incoming)),
    )
    assertEquals(
      "Chiamata in corso",
      sipNotificationTitle(SipState(status = SipRegistrationStatus.Registered, callStatus = SipCallStatus.Calling)),
    )
    assertEquals(
      "In conversazione",
      sipNotificationTitle(SipState(status = SipRegistrationStatus.Registered, callStatus = SipCallStatus.Active)),
    )
  }

  @Test
  fun sipNotificationTitle_reflectsRegistrationWhenIdleCall() {
    assertEquals(
      "Telefono Iànua · Registrato",
      sipNotificationTitle(SipState(status = SipRegistrationStatus.Registered)),
    )
    assertEquals(
      "Telefono Iànua · Registrazione…",
      sipNotificationTitle(SipState(status = SipRegistrationStatus.Registering)),
    )
    assertEquals(
      "Telefono Iànua · Registrazione…",
      sipNotificationTitle(SipState(status = SipRegistrationStatus.Loading)),
    )
    assertEquals("Telefono Iànua", sipNotificationTitle(SipState()))
  }

  @Test
  fun sipNotificationText_showsPeerDuringCallAndExtensionWhenRegistered() {
    assertEquals(
      "204",
      sipNotificationText(
        SipState(status = SipRegistrationStatus.Registered, callStatus = SipCallStatus.Active, activePeer = "204"),
      ),
    )
    assertEquals(
      "Interno sconosciuto",
      sipNotificationText(SipState(status = SipRegistrationStatus.Registered, callStatus = SipCallStatus.Incoming)),
    )
    assertEquals(
      "Interno 212 pronto",
      sipNotificationText(SipState(status = SipRegistrationStatus.Registered, extension = "212")),
    )
    assertEquals(
      "In attesa della configurazione",
      sipNotificationText(SipState(status = SipRegistrationStatus.Loading)),
    )
  }
}
