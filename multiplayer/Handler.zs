class MultiplayerPingTracer : LineTracer
{
	override ETraceStatus TraceCallback()
	{
		if (Results.HitType == TRACE_HitActor)
		{
			if (Results.HitActor.Player || Results.HitActor.bKilled
				|| (!Results.HitActor.bIsMonster && !(Results.HitActor is "Inventory") && !(Results.HitActor is "MultiplayerLocation")))
			{
				return TRACE_Skip;
			}
		}

		return TRACE_Stop;
	}
}

class MultiplayerLocation : Actor
{
	Default
	{
		FloatBobPhase 0u;
		Radius 6.0;
		Height 12.0;
		RenderStyle "Add";
		Alpha 0.5;
		Tag "Location";

		+FORCEXYBILLBOARD
		+MOVEWITHSECTOR
		+BRIGHT
		+NOSAVEGAME
        +DONTBLAST
        +NOTONAUTOMAP
		+SYNCHRONIZED
	}

	States
	{
		Spawn:
			AMRK A -1;
			Loop;
	}

	override void BeginPlay()
    {
        Super.BeginPlay();

        ChangeStatNum(MAX_STATNUM);
		Scale.Y = 1.0 / Level.PixelStretch;
    }

    override void Tick()
    {
        if ((FreezeTics && --FreezeTics >= 0u) || IsFrozen())
            return;

        if (CheckNoDelay() && Tics > 0 && --Tics <= 0)
            SetState(CurState.NextState);
    }
}

class MultiplayerPingMarker : MapMarker
{
	Default
	{
		FloatBobPhase 0u;
		Radius 0.0;
		Height 0.0;
		Scale 0.33335;

		+SYNCHRONIZED
		+DONTBLAST
		+NOINTERACTION
		+NOSAVEGAME
	}

	override void PostBeginPlay()
	{
		Super.PostBeginPlay();

		State head = Master.SpawnState;
		State cur = head;
		while (cur && cur.Sprite <= 2 && cur.NextState != head)
			cur = cur.NextState;

		if (cur)
			Sprite = cur.Sprite;

		if (!(Master is "MultiplayerLocation"))
			Scale.Y *= Level.PixelStretch;
	}
}

class MultiplayerPingInfo play
{
	private PlayerInfo master;
	private Actor mo;
	private int timer;
	private MapMarker marker;

	static MultiplayerPingInfo Create(PlayerInfo master, Actor mo, double timer, MapMarker marker)
	{
		let pi = new("MultiplayerPingInfo");
		pi.master = master;
		pi.mo = mo;
		pi.timer = int(Ceil(timer * GameTicRate));
		pi.marker = marker;
		if (pi.marker)
			pi.marker.Master = pi.mo;

		return pi;
	}

	clearscope bool IsMaster(PlayerInfo p) const
	{
		return master && master == p;
	}

	clearscope bool IsMobj(Actor mobj) const
	{
		return mo && mo == mobj;
	}

	clearscope bool IsType(class<Actor> type) const
	{
		return mo && mo is type;
	}

	clearscope PlayerInfo GetMaster() const
	{
		return master;
	}

	clearscope Actor GetMobj() const
	{
		return mo;
	}

	bool Tick()
	{
		if (!mo || mo.bKilled || --timer <= 0)
			return false;

		bool isTDM = multiplayer && deathmatch && teamplay;
		if (!master.Mo && (isTDM || mo is "MultiplayerLocation"))
			return false;

		let inv = Inventory(mo);
		if (inv && inv.Owner)
			return false;

		mo.bInvisible = isTDM && mo is "MultiplayerLocation" && Players[ConsolePlayer].Camera.IsHostile(master.Mo);
		if (marker)
			marker.SetOrigin(mo.Pos, true);

		return true;
	}

	override void OnDestroy()
	{
		Super.OnDestroy();

		if (mo is "MultiplayerLocation")
			mo.Destroy();
		if (marker)
			marker.Destroy();
	}
}

class MultiplayerLivesManager : Thinker
{
    const SURVIVAL_END_DELAY = 4.0;

	private int lives;
	private int playerLives[MAXPLAYERS];
	private int curDamage;
    private bool bSurvivalEnded;
    private int endTimer;
	
	static MultiplayerLivesManager Get()
	{
		let lm = MultiplayerLivesManager(ThinkerIterator.Create("MultiplayerLivesManager", STAT_STATIC).Next());
		if (!lm)
		{
			lm = new("MultiplayerLivesManager");
			lm.ChangeStatNum(STAT_STATIC);
			lm.Reset();
		}
			
		return lm;
	}
	
	clearscope int GetLives(int pNum) const
	{
		return mpp_individuallives ? playerLives[pNum] : lives;
	}
	
	clearscope int GetNextLife() const
	{
		return Max(mpp_livesdamagethreshold - curDamage, 0);
	}

    clearscope bool HasGameEnded() const
    {
        return bSurvivalEnded;
    }

	clearscope bool CanRespawn(int pNum) const
	{
		if (!mpp_survival)
			return true;
        if (bSurvivalEnded)
            return false;

		return (mpp_individuallives ? playerLives[pNum] : lives) > 0;
	}

	clearscope bool IsEveryoneDead() const
	{
		if (!mpp_survival)
			return false;
			
		for (int i; i < MAXPLAYERS; ++i)
		{
			if (PlayerInGame[i] && Players[i].PlayerState == PST_LIVE)
				return false;
		}
		
        if (mpp_individuallives)
        {
            for (int i; i < MAXPLAYERS; ++i)
            {
                if (PlayerInGame[i] && playerLives[i] > 0)
					return false;
            }
            
            return true;
        }

        return lives <= 0;
	}
	
	void Reset()
	{
        bSurvivalEnded = false;
        endTimer = curDamage = 0;
		lives = mpp_lives;
		for (int i; i < MAXPLAYERS; ++i)
			playerLives[i] = mpp_lives;
	}

    void UpdateGame()
    {
        if (!bSurvivalEnded)
        {
            bSurvivalEnded = IsEveryoneDead();
            if (bSurvivalEnded)
                endTimer = int(ceil(SURVIVAL_END_DELAY * GameTicRate));
        }

        if (!bSurvivalEnded)
            return;

        if (--endTimer <= 0)
        {
            Reset();
            Level.ChangeLevel(Level.MapName, flags: CHANGELEVEL_RESETHEALTH|CHANGELEVEL_RESETINVENTORY);
        }
    }
	
	void AddDamage(int amt)
	{
		if (!mpp_survival || amt <= 0 || mpp_livesdamagethreshold <= 0)
			return;
			
		curDamage += amt;
		int toAdd;
		while (curDamage >= mpp_livesdamagethreshold)
		{
			++toAdd;
			curDamage -= mpp_livesdamagethreshold;
		}
				
		lives += toAdd;
		for (int i; i < MAXPLAYERS; ++i)
			playerLives[i] += toAdd;
	}
	
	void PlayerDied(int pNum)
	{
		if (!mpp_survival)
			return;
		
		if (mpp_individuallives)
			--playerLives[pNum];
		else
			--lives;
	}
}

class MultiplayerHandler : StaticEventHandler
{
	// Base functionality

	clearscope static bool IsCoop()
	{
		return multiplayer && !deathmatch;
	}

	// Overrides

	override void WorldLoaded(WorldEvent e)
    {
		// TODO: This probably breaks hubs...
        if (!e.IsReopen && !e.IsSaveGame)
            ResetLives();
    }

	override void WorldUnloaded(WorldEvent e)
    {
        // Since pings can reside even after a player leaves, everyone has
        // to be cleared.
        for (int i; i < MAXPLAYERS; ++i)
            ClearPings(Players[i]);
    }

	override void WorldTick()
    {
        UpdatePings();
		UpdateTeleportCooldowns();
		UpdateLives();
    }

	override void WorldThingDamaged(WorldEvent e)
    {
        if (e.DamageSource && e.DamageSource.Player && (!e.Thing || (e.Thing.bIsMonster && !e.DamageSource.IsFriend(e.Thing))))
        {
            int dmg = 100;
            if (e.Thing)
            {
                dmg = e.Damage;
                if (e.Thing.Health < 0)
                    dmg += e.Thing.Health;
            }

            if (dmg > 0)
            	AddLivesDamage(dmg);
        }
    }

	override bool PlayerRespawning(PlayerEvent e)
	{
		return HasLivesToRespawn(e.PlayerNumber);
	}

	override void PlayerDied(PlayerEvent e)
    {
        RemoveLives(e.PlayerNumber);
    }

	override void RenderUnderlay(RenderEvent e)
    {
        DrawPings(e);
    }

	override void RenderOverlay(RenderEvent e)
    {
        DrawLives(e.FracTic);
    }

	override void NetworkProcess(ConsoleEvent e)
	{
		if (e.Name ~== "MPPPing")
		{
			if (multiplayer && (!deathmatch || teamplay))
				SetPing(Players[e.Player]);
		}
		else if (e.Name ~== "MPPClearPings")
		{
			if (multiplayer && (!deathmatch || teamplay))
				ClearPings(Players[e.Player]);
		}
		else if (e.Name ~== "MPPTeleport")
		{
			if (IsCoop())
				TeleportToAlly(e.Player);
		}
	}

	// Pinging

	const PING_TIME = 20.0;
	const PING_RANGE = 8096.0;
	const H_FONT_SCALE = 3.0;
    const V_FONT_SCALE = H_FONT_SCALE * 1.2;
    const NAME_RANGE_SQ = 0.0144;
    const ALLY_COLOR = 0xFF3282BE;
    const ENEMY_COLOR = 0xFFEB821E;

	enum EScreenSide
    {
        SIDE_INSIDE = 0,
        SIDE_RIGHT = 1,
        SIDE_LEFT = ~1,
        SIDE_TOP = 2,
        SIDE_BOTTOM = ~2
    }

	private ui MultiplayerGMProjectionCache cache;
    private ui Shape2D marker;
    private ui Shape2DTransform t;

	private MultiplayerPingTracer _pingTracer;
	private Array<MultiplayerPingInfo> pings;

	MultiplayerPingTracer GetPingTracer()
	{
		if (!_pingTracer)
			_pingTracer = new("MultiplayerPingTracer");

		return _pingTracer;
	}

	private ui Shape2D, Shape2DTransform GetMarker() const
    {
        let shape = new("Shape2D");

        shape.PushVertex((-0.5, -0.5));
        shape.PushVertex((0.5, -0.5));
        shape.PushVertex((0.0, 0.5));

        shape.PushCoord((0.0, 0.0));
        shape.PushCoord((1.0, 0.0));
        shape.PushCoord((0.5, 1.0));

        shape.PushTriangle(0, 1, 2);

        return shape, new("Shape2DTransform");
    }

	private ui bool, bool PlayerInView(Vector3 ndc, double distSq) const
    {
        if (ndc.x < -1.0 || ndc.x > 1.0
            || ndc.y < -1.0 || ndc.y > 1.0
            || ndc.z < -1.0 || ndc.z > 1.0)
        {
            return false, false;
        }

        return true, (ndc.xy dot ndc.xy) <= distSq;
    }

	private ui EScreenSide, double MarkerSide(Vector3 ndc) const
    {
        double multi = 1.0;
        EScreenSide s = SIDE_INSIDE;
        if (ndc.x < -1.0)
            s = SIDE_LEFT;
        else if (ndc.x > 1.0)
            s = SIDE_RIGHT;
        else if (ndc.y < -1.0)
            s = SIDE_BOTTOM;
        else if (ndc.y > 1.0)
            s = SIDE_TOP;

        if (ndc.z < -1.0 || ndc.z > 1.0)
        {
            if (s == SIDE_INSIDE)
            {
                if (ndc.y > 0.0)
                    s = SIDE_TOP;
                else if (ndc.y < 0.0)
                    s = SIDE_BOTTOM;
                else if (ndc.x > 0.0)
                    s = SIDE_RIGHT;
                else if (ndc.x < 0.0)
                    s = SIDE_LEFT;
            }

            s = ~s;
            multi = -1.0;
        }

        return s, multi;
    }

	void AddPing(Actor mo, PlayerInfo master)
	{
		if (mo)
			pings.Push(MultiplayerPingInfo.Create(master, mo, PING_TIME, MapMarker(Actor.Spawn("MultiplayerPingMarker", mo.pos))));
	}

	void RemovePing(int index)
	{
		if (index < 0 || index >= pings.Size())
			return;

		pings[index].Destroy();
		pings.Delete(index);
	}

	void UpdatePings()
	{
		for (int i = pings.Size() - 1; i >= 0; --i)
		{
			if (!pings[i].Tick())
				RemovePing(i);
		}
	}

	void ClearPings(PlayerInfo master)
	{
		for (int i = pings.Size()-1; i >= 0; --i)
		{
			if (pings[i].IsMaster(master))
				RemovePing(i);
		}
	}

	clearscope MultiplayerPingInfo, int FindPing(Actor mo) const
	{
		if (!mo)
			return null, pings.Size();

		for (int i; i < pings.Size(); ++i)
		{
			if (pings[i].IsMobj(mo))
				return pings[i], i;
		}

		return null, pings.Size();
	}

	clearscope MultiplayerPingInfo, int FindLocation(PlayerInfo master) const
	{
		for (int i; i < pings.Size(); ++i)
		{
			if (pings[i].IsMaster(master) && pings[i].IsType("MultiplayerLocation"))
				return pings[i], i;
		}

		return null, pings.Size();
	}

	void SetPing(PlayerInfo caller)
	{
		let player = caller.mo;
		Vector3 start = (player.Pos.XY, caller.ViewZ);
		Vector3 dir = (player.Angle.ToVector() * Cos(player.Pitch), -Sin(player.Pitch));

		let pt = GetPingTracer();
		if (pt.Trace(start, player.CurSector, dir, PING_RANGE, 0, Line.ML_BLOCKEVERYTHING, ignore: player))
		{
			if (pt.Results.HitType == TRACE_HitActor)
			{
				let [ping, index] = FindPing(pt.Results.HitActor);
				if (!ping)
				{
					AddPing(pt.Results.HitActor, caller);
				}
				else
				{
					bool isMaster = ping.IsMaster(caller);
					RemovePing(index);
					if (!isMaster)
						AddPing(pt.Results.HitActor, caller);
				}
			}
			else
			{
				let [spot, index] = FindLocation(caller);
				if (spot)
					RemovePing(index);

				Actor mo = Actor.Spawn("MultiplayerLocation", pt.Results.HitPos.PlusZ(-6.0));
				if (mo.pos.z < mo.floorZ)
					mo.SetZ(mo.floorZ);
				else if (mo.pos.z + mo.height > mo.ceilingZ)
					mo.SetZ(mo.ceilingZ - mo.height);

				if (pt.Results.HitType == TRACE_HitWall)
				{
					Vector3 normal;
					if (Level.PointOnLineSide(pt.Results.hitPos.xy - pt.Results.hitVector.xy.Unit(), pt.Results.hitLine))
						normal.xy = (-pt.Results.hitLine.delta.y, pt.Results.hitLine.delta.x);
					else
						normal.xy = (pt.Results.hitLine.delta.y, -pt.Results.hitLine.delta.x);

					normal = normal.Unit();
					mo.SetOrigin(Level.Vec3Offset(mo.pos, normal * mo.radius), false);
				}

				AddPing(mo, caller);
			}
		}
	}

	ui void DrawPings(RenderEvent e)
    {
        if (automapActive || (!multiplayer && !pings.Size()))
            return;

        if (!cache)
            cache = new("MultiplayerGMProjectionCache");
        if (!marker)
            [marker, t] = GetMarker();

        cache.CalculateMatrices(Screen.GetAspectRatio(), e.camera.player ? e.camera.player.fov : e.camera.cameraFOV,
                                e.viewPos, e.viewAngle, e.viewPitch, e.viewRoll);

        let [x, y, w, h] = Screen.GetViewWindow();

        double scale = (y ? h : Screen.GetHeight()) / 1080.0;
        Vector2 size = (30.0, 15.0) * scale;
        Vector2 yOfs = (0.0, size.y*0.5);
        Vector2 fScale = (H_FONT_SCALE, V_FONT_SCALE) * scale;
        double hOfs = ConFont.GetHeight() * fScale.y + yOfs.y;

        let [cx, cy, cw, ch] = Screen.GetClipRect();
        Screen.SetClipRect(x, y, w, h);

        // Draw player tags.
        for (int i; i < MAXPLAYERS; ++i)
        {
            if (!PlayerInGame[i] || Players[i] == e.camera.player)
                continue;

			bool hostile = e.camera.IsHostile(Players[i].mo);
			if (hostile)
				continue;

            Vector3 pos = MultiplayerGMVectorUtil.LerpUnclampedVec3(players[i].mo.prev, players[i].mo.pos, e.fracTic).PlusZ(players[i].mo.height - players[i].mo.floorClip);

            Vector3 ndc = cache.worldToClip.MultiplyVector3(e.viewPos + level.Vec3Diff(e.viewPos, pos));
            let [inView, drawText] = PlayerInView(ndc, NAME_RANGE_SQ);
            if (!inView)
                continue;

            Vector2 coord = MultiplayerGMGlobalMaths.NDCToViewport(ndc) - yOfs;

            t.Clear();
            t.Scale(size);
            t.Translate(coord);
            marker.SetTransform(t);

            // this uses BGR so we need to swap the color
			Color col = hostile ? ENEMY_COLOR : ALLY_COLOR;
            Screen.DrawShapeFill(0, 1, marker, DTA_ColorOverlay, col);

            if (drawText)
            {
                string title = players[i].GetUserName(12u);
                double wOfs = ConFont.StringWidth(title) * 0.5 * fScale.x;
                Screen.DrawText(ConFont, -1, coord.x-wOfs, coord.y-hOfs, title,
                                DTA_ScaleX, fScale.x, DTA_ScaleY, fScale.y, DTA_Color, col);
            }
        }

        // draw pings
        foreach (ping : pings)
        {
			Actor mo = ping.GetMobj();
			if (!mo)
				continue;

			let master = ping.GetMaster();
			if (master.mo && e.camera.IsHostile(master.mo))
				continue;

            Vector3 pos = MultiplayerGMVectorUtil.LerpUnclampedVec3(mo.prev, mo.pos, e.fracTic).PlusZ(mo.height - mo.floorClip);
            Vector3 ndc = cache.worldToClip.MultiplyVector3(e.viewPos + level.Vec3Diff(e.viewPos, pos));
            let [side, multi] = MarkerSide(ndc);
            ndc *= multi;

            Vector2 coord = MultiplayerGMGlobalMaths.NDCToViewport(ndc) - yOfs;
            double rot;
            switch (side)
            {
                case SIDE_LEFT:
                    coord.x = x + yOfs.y;
                    rot = 90.0;
                    break;

                case SIDE_RIGHT:
                    coord.x = x + w - yOfs.y;
                    rot = -90.0;
                    break;

                case SIDE_TOP:
                    coord.y = y + yOfs.y;
                    rot = 180.0;
                    break;

                case SIDE_BOTTOM:
                    coord.y = y + h - yOfs.y;
                    break;
            }

            t.Clear();
            t.Scale(size);
            t.Rotate(rot);
            t.Translate(coord);
            marker.SetTransform(t);

			Color col = 0xFFFFFFFF;
			if (mo.bIsMonster)
			{
				if (mo.IsHostile(e.camera))
					col = ENEMY_COLOR;
				else if (mo.IsFriend(e.camera))
					col = ALLY_COLOR;
			}

            // This uses BGR so we need to swap the color
            Screen.DrawShapeFill(0, 1, marker, DTA_ColorOverlay, col);

            if (side == SIDE_INSIDE)
            {
                string title = mo.GetCharacterName();
                double wOfs = ConFont.StringWidth(title) * 0.5 * fScale.x;
                Screen.DrawText(ConFont, -1, coord.x-wOfs, coord.y-hOfs, title,
                                DTA_ScaleX, fScale.x, DTA_ScaleY, fScale.y, DTA_Color, col);
            }
        }

        Screen.SetClipRect(cx, cy, cw, ch);
    }

	// Teleport handling

	const MAX_TELEPORT_ANG = cos(15.0);

	private int teleportCooldown[MAXPLAYERS];

	void TeleportToAlly(int pNum)
	{
		let player = players[pNum];
		if (player.playerstate == PST_DEAD || !mpp_allowteleport)
			return;

		if (teleportCooldown[pNum] > 0)
		{
			if (pNum == consoleplayer)
				Console.Printf("You must wait %d second(s) before being able to teleport", teleportCooldown[pNum] / GameTicRate);

			return;
		}

		Vector3 view = (player.mo.Pos.XY, player.ViewZ);
		Vector3 facing = (player.mo.Angle.ToVector() * cos(player.mo.Pitch), -sin(player.mo.Pitch));

		int closest = -1;
		double lowDist = double.infinity;
		double lowAng = -double.infinity;
		for (int i; i < MAXPLAYERS; ++i)
		{
			if (i == pNum || !playeringame[i] || players[i].playerstate == PST_DEAD)
				continue;

			Vector3 dir = Level.Vec3Diff(view, players[i].mo.Pos.PlusZ(players[i].mo.Height * 0.5));
			double dist = dir.Length();
			if (dist ~== 0.0)
				continue;

			double ang = facing dot (dir / dist);
			if (ang < MAX_TELEPORT_ANG)
				continue;

			if (ang > lowAng || (ang ~== lowAng && dist < lowDist))
			{
				closest = i;
				lowDist = dist;
				lowAng = ang;
			}
		}

		if (closest == -1)
			return;

		teleportCooldown[pNum] = 10 * GameTicRate;
		player.mo.SetOrigin(players[closest].mo.Pos, false);
		let fog = Actor.Spawn(player.mo.TeleFogDestType, player.mo.Pos, ALLOW_REPLACE);
		if (fog)
			fog.Target = player.mo;
	}

	protected void UpdateTeleportCooldowns()
	{
		for (int i; i < MAXPLAYERS; ++i)
		{
			if (teleportCooldown[i] > 0)
				--teleportCooldown[i];
		}
	}

	// Survival

	private MultiplayerLivesManager livesManager;

    MultiplayerLivesManager GetLivesManager()
    {
        if (!livesManager)
            livesManager = MultiplayerLivesManager.Get();

        return livesManager;
    }
	
	void ResetLives()
	{
        if (mpp_resetlives && IsCoop())
            GetLivesManager().Reset();
	}
	
	void UpdateLives()
	{
		if (IsCoop())
            GetLivesManager().UpdateGame();
	}

    void RemoveLives(int pNum)
    {
        if (IsCoop())
            GetLivesManager().PlayerDied(pNum);
    }

    void AddLivesDamage(int dmg)
    {
        if (IsCoop())
            GetLivesManager().AddDamage(dmg);
    }

	bool HasLivesToRespawn(int pNum)
	{
		if (IsCoop())
			return GetLivesManager().CanRespawn(pNum);

		return true;
	}
	
	ui void DrawLives(double ticFrac)
	{
		if (!mpp_survival || !livesManager || !IsCoop())
			return;

		double realScalar = Screen.GetHeight() / 1080.0;
		Vector2 scale = (2.0, 2.4) * realScalar;
        double center = Screen.GetWidth() * 0.5;
        if (livesManager.HasGameEnded())
        {
            string gameOver = StringTable.Localize("$MPP_GAMEOVER");
            double x = center - BigFont.StringWidth(gameOver) * 0.5 * scale.X;
            Screen.DrawText(BigFont, Font.CR_UNTRANSLATED, center, 0.0, gameOver, DTA_ScaleX, scale.X, DTA_ScaleY, scale.Y);
            return;
        }
		
        string text = String.Format(StringTable.Localize("$MPP_LIVES"), livesManager.GetLives(ConsolePlayer));
        double x = center - BigFont.StringWidth(text) * 0.5 * scale.X;
		Screen.DrawText(BigFont, Font.CR_UNTRANSLATED, x, 0.0, text, DTA_ScaleX, scale.X, DTA_ScaleY, scale.Y);
		if (mpp_livesdamagethreshold > 0)
        {
			text = String.Format(StringTable.Localize("$MPP_NEXTLIFE"), livesManager.GetNextLife());
            x = center - BigFont.StringWidth(text) * 0.375 * scale.X;
			Screen.DrawText(BigFont, Font.CR_UNTRANSLATED, x, BigFont.GetHeight() * scale.Y, text, DTA_ScaleX, scale.X * 0.75, DTA_ScaleY, scale.Y * 0.75);
        }
	}
}