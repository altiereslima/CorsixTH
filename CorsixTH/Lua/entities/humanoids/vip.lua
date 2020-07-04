--[[ Copyright (c) 2011-2020 John Pirie, lewri

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE. --]]

--[[
---------------------------------- VIP Rating System --------------------------------
Vip rating is calculated between 0 and 15
If rating exceeds values, it will be capped as necessary
1. LITTER OBJECTS
 - a. General litter and vomit 'litter' is counted
 - b. At end of visit, if number <=10 award -1
 - c. Otherwise, award +1
2. STAFF TIREDNESS
 - a. If staff <=1, award +4 and skip other checks
 - b. If any staff member very tired (over 0.7), award 2
 - c. If average staff tiredness over tired (0.5), award 1
 - d. Else award -1
3. PATIENTS
 - a. If average patient health >= 0.2, award -1
 - b. If average patient health < 0.2, award +1
 - c. Assess patient warmth, too hot/cold award +2, perfect -1, just over 1
 - d. Average happiness, award 3 if <0.2; 2 if <0.4, 1 if <0.6, 0 if <0.8, else -1
 - e. Check if anyone has died during visit, punish based on severity
 - f. Check how many patients are cured vs. all patients, award based on %
 - g. Check seating. Award -1 for more seated than standing, else +1
 - h. Check average queues. Award based on the average length
4. DOCTOR
 - a. If no doctors, award +4 and skip other checks
 - b. If more than half doctors are consultants, award -2
 - c. If more than half doctors are juniors, award +2
5. ROOMS
 - a. If there are no active rooms, award +4
 - b. If rooms not crashed (exploded) <3, award +1
 - c. Get average room evaluation score, award based on average level
-------------------------------------------------------------------------------------
--]]

--[[ initialisation --]]
corsixth.require("announcer")

local AnnouncementPriority = _G["AnnouncementPriority"]

--! A `Vip` who is in the hospital to evaluate the hospital and produce a report
class "Vip" (Humanoid)

---@type Vip
local Vip = _G["Vip"]

function Vip:Vip(...)
  self:Humanoid(...)
  self.hover_cursor = TheApp.gfx:loadMainCursor("default")
  self.action_string = ""
  self.name=""
  self.announced = false
  --First we should generate an initial VIP rating
  self.vip_rating = 12 - math.random(0,5)

  self.cash_reward = 0
  self.rep_reward = 0
  self.vip_message = 0
  self.enter_deaths = 0
  self.enter_visitors = 0
  -- patients in the hospital when VIP arrives
  self.enter_patients = 0
  self.enter_explosions = 0
  self.num_vomit_noninducing = 0
  self.num_vomit_inducing = 0
  self.found_vomit = {}
  self.num_visited_rooms = 0
  self.room_eval = 0
  -- sets the chance VIP visits each room, default is 50% or 1/2. For every 40 rooms in a hospital over 79 we increase n by 1 and chance is 1/n+1
  self.room_visit_chance = 1
  self.waiting = 0

end

--[[--VIP while on premesis--]]
function Vip:tickDay()
  -- for the vip
  if self.waiting then
    self.waiting = self.waiting - 1
    if self.waiting == 0 then
      if #self.world.rooms == 0 then
        -- No rooms have been built yet
        self:goHome()
      end
      self:getNextRoom()
      self.waiting = nil
    end
  end

  self.world:findObjectNear(self, "litter", 8, function(x, y)
    local litter = self.world:getObject(x, y, "litter")
    if not litter then
      return
    end

    local alreadyFound = false
    for i=1, (self.num_vomit_noninducing + self.num_vomit_inducing) do
      if self.found_vomit[i] == litter then
        alreadyFound = true
        break
      end
    end

    self.found_vomit[(self.num_vomit_noninducing + self.num_vomit_inducing + 1)] = litter

    if not alreadyFound then
      if litter:anyLitter() then
        self.num_vomit_noninducing = self.num_vomit_noninducing + 1
      else
        self.num_vomit_inducing = self.num_vomit_inducing + 1
      end
    end
  end)

  return Humanoid.tickDay(self)
end

function Vip:getNextRoom()
  -- First let the previous room go.
  -- Include this when the VIP is supposed to block doors again.
  --[[if self.next_room then
        self.next_room.door.reserved_for = nil
        self.next_room:tryAdvanceQueue()
      end--]]
  -- Find out which next room to visit.
  self.next_room_no, self.next_room = next(self.world.rooms, self.next_room_no)
  if self.next_room ~= nil then
    local roll_to_visit = math.random(0, self.room_visit_chance)
    while self.num_visited_rooms > 0 and roll_to_visit ~= self.room_visit_chance and not self.next_room.room_info.vip_must_visit do
      self.next_room_no, self.next_room = next(self.world.rooms, self.next_room_no)
      if self.next_room == nil then
        break
      end
      roll_to_visit = math.random(0, self.room_visit_chance)
    end
    -- Make sure that this room is active; if not, always visit the next available room
    while self.next_room and not self.next_room.is_active do
      self.next_room_no, self.next_room = next(self.world.rooms, self.next_room_no)
    end
  end
  self:setNextAction(VipGoToNextRoomAction())
end

-- display the VIP name in the info box
function Vip:updateDynamicInfo(action_string)
  self:setDynamicInfo('text', {self.name})
end

--[[--VIP is leaving--]]
function Vip:goHome()
  if self.going_home then
    return
  end

  self:unregisterCallbacks()
  -- Set the rating.
  self:setVIPRating()

  self.going_home = true
  -- save self.hospital so we can reference it in self:onDestroy
  self.last_hospital = self.hospital
  self:despawn()
end

function Vip:evaluateRoom()
  local room_extinguisher = 0
  local room_plant = 0
  local room_bin = 0
  -- Another room visited.
  self.num_visited_rooms = self.num_visited_rooms + 1
  local room = self.next_room
  -- if the player is about to kill a live patient for research, punish hard
  if room.room_info.id == "research" then
    if room:getPatient() then
      self.vip_rating = self.vip_rating + 6
    end
  end
  -- evaluate the room we're currently looking at
  for object, _ in pairs(room.objects) do
    if object.object_type.id == "extinguisher" and room_extinguisher == 0 then
      self.room_eval = self.room_eval + 1
      -- only count this object type once
      room_extinguisher = 1
    elseif object.object_type.id == "plant" then
      if object.days_left >= 10 then
        room_plant = room_plant + 1
      elseif object.days_left <= 3 then
        room_plant = room_plant - 1
      end
    elseif object.object_type.id == "bin" and room_bin == 0 then
      self.room_eval = self.room_eval + 1
      -- only count this object type once
      room_bin = 1
    end

    if object.strength then
      if object.strength > (object.object_type.default_strength / 2) then
        self.room_eval = self.room_eval + 1
      else
        self.room_eval = self.room_eval - 1
      end
    end
  end
  --check whether we had more good or bad plants
  if room_plant < 0 then
    self.room_eval = self.room_eval - 1
  elseif room_plant > 0 then
    self.room_eval = self.room_eval + 1
  end
  self:getNextRoom()
end

--[[--VIP has left--]]
-- called when the vip is out of the hospital grounds
function Vip:onDestroy()
  local message
  -- First of all there's a special message if we're in free build mode.
  if self.world.free_build_mode then
    self.last_hospital.reputation = self.last_hospital.reputation + 20
    message = {
      {text = _S.fax.vip_visit_result.vip_remarked_name:format(self.name)},
      {text = _S.fax.vip_visit_result.remarks.free_build[math.random(1, 3)]},
      choices = {{text = _S.fax.vip_visit_result.close_text, choice = "close"}}
    }
  elseif self.vip_rating <= 7 then
    self.last_hospital:receiveMoney(self.cash_reward, _S.transactions.vip_award)
    self.last_hospital.reputation = self.last_hospital.reputation + self.rep_reward
    self.last_hospital.pleased_vips_ty = self.last_hospital.pleased_vips_ty + 1
    message = {
      {text = _S.fax.vip_visit_result.vip_remarked_name:format(self.name)},
      {text = _S.fax.vip_visit_result.ordered_remarks[self.vip_message]},
      {text = _S.fax.vip_visit_result.rep_boost},
      {text = _S.fax.vip_visit_result.cash_grant:format(self.cash_reward)},
      choices = {{text = _S.fax.vip_visit_result.close_text, choice = "close"}}
    }
  elseif self.vip_rating >=8 and self.vip_rating < 11 then
    -- dont tell player about any rep change in this range
    self.last_hospital.reputation = self.last_hospital.reputation + self.rep_reward
    message = {
      {text = _S.fax.vip_visit_result.vip_remarked_name:format(self.name)},
      {text = _S.fax.vip_visit_result.ordered_remarks[self.vip_message]},
      choices = {{text = _S.fax.vip_visit_result.close_text, choice = "close"}}
    }
  else
    self.last_hospital.reputation = self.last_hospital.reputation + self.rep_reward
    message = {
      {text = _S.fax.vip_visit_result.vip_remarked_name:format(self.name)},
      {text = _S.fax.vip_visit_result.ordered_remarks[self.vip_message]},
      {text = _S.fax.vip_visit_result.rep_loss},
      choices = {{text = _S.fax.vip_visit_result.close_text, choice = "close"}}
    }
  end
  self.world.ui.bottom_panel:queueMessage("report", message, nil, 24 * 20, 1)

  self.world:nextVip()

  return Humanoid.onDestroy(self)
end

function Vip:announce()
  local announcements = {
    "vip001.wav", "vip002.wav", "vip003.wav", "vip004.wav", "vip005.wav",
  }   -- there is also vip008 which announces a man from the ministry
  self.world.ui:playAnnouncement(announcements[math.random(1, #announcements)], AnnouncementPriority.High)
  if self.hospital.num_vips < 1 then
    self.world.ui.adviser:say(_A.information.initial_general_advice.first_VIP)
  else
    self.world.ui.adviser:say(_A.information.vip_arrived:format(self.name))
  end
end

function Vip:setVIPRating()
  -- first do room code for later
  local count_rooms = 0
  local sum_queue = 0
  for _, room in pairs(self.world.rooms) do
    if not room.crashed then
      count_rooms = count_rooms + 1
    end
    if room.door.queue then
      sum_queue = sum_queue + room.door.queue:size()
    end
  end

--[[-- Group factor 1: Litter--]]
  if (self.num_vomit_noninducing + self.num_vomit_inducing) <= 10 then
    self.vip_rating = self.vip_rating - 1
  else
    self.vip_rating = self.vip_rating + 1
  end

--[[-- Group factor 2: Staff tiredness--]]
  -- First get staff members
  local count_staff = #self.hospital.staff
  if count_staff > 1 then
    -- Loop through staff tiredness, if any above verytired, break loop
    for _, staff in ipairs(self.hospital.staff) do
      if staff.attributes["fatigue"] ~= nil and staff.attributes["fatigue"] >= 0.7 then
        self.vip_rating = self.vip_rating + 2
        break
      end
    end
    -- Average all staff tiredness. If above tiredness level award 1, else -1
    local avg_tired = self.hospital:getAverageStaffAttribute("fatigue", 1)
    if avg_tired >= 0.5 then
      self.vip_rating = self.vip_rating + 1
    else
      self.vip_rating = self.vip_rating - 1
    end
  else
    -- Penalise where there is one or no staff
    self.vip_rating = self.vip_rating + 4
  end

--[[-- Group factor 3: Patients--]]
  -- first check we had patients this visit
  local patients_this_visit = self.enter_patients + self.hospital.num_visitors - self.enter_visitors
  if patients_this_visit > 0 then
    -- Average all patient health
    local avg_health = self.hospital:getAveragePatientAttribute("health", 0.19)
    if avg_health >= 0.2 then
      self.vip_rating = self.vip_rating - 1
    else
      self.vip_rating = self.vip_rating + 1
    end

    -- get patient warmth
    local avg_warmth = self.hospital:getAveragePatientAttribute("warmth", nil)
    -- punish if too cold/hot
    if avg_warmth then
      local patients_warmth_ratio_rangemap = {
        {upper = 0.21, value = 2},
        {upper = 0.36, value = -1},
        {upper = 0.43, value = 1},
        {value = 2}
      }
      self.vip_rating = self.vip_rating + rangeMapLookup(avg_warmth, patients_warmth_ratio_rangemap)
    end

    -- check average patient happiness
    local avg_happiness = self.hospital:getAveragePatientAttribute("happiness", nil)
    if avg_happiness then
      local patients_happy_ratio_rangemap = {
        {upper = 0.20, value = 3},
        {upper = 0.40, value = 2},
        {upper = 0.60, value = 1},
        {upper = 0.80, value = 0},
        {value = -1}
      }
      self.vip_rating = self.vip_rating + rangeMapLookup(avg_happiness, patients_happy_ratio_rangemap)
    end

    --check the visitor to patient death ratio
    local death_diff = self.hospital.num_deaths - self.enter_deaths
    if death_diff ~= 0 then --no deaths are good, but also expected
      local death_ratio = patients_this_visit / death_diff
      local death_ratio_rangemap = {
        {upper = 2, value = 4},
        {upper = 4, value = 3},
        {upper = 8, value = 2},
        {upper = 12, value = 1},
        {value = 0}
      }
      self.vip_rating = self.vip_rating + rangeMapLookup(death_ratio, death_ratio_rangemap)
    end

    --check the visitor to patient cure ratio
    local cure_diff = self.hospital.num_cured - self.enter_cures
    if cure_diff ~= 0 then --no cures are bad
      local cure_ratio = patients_this_visit / cure_diff
      local cure_ratio_rangemap = {
        {upper = 2, value = -1},
        {upper = 3, value = 0},
        {upper = 4, value = 1},
        {upper = 5, value = 2},
        {value = 3}
      }
      self.vip_rating = self.vip_rating + rangeMapLookup(cure_ratio, cure_ratio_rangemap)
    else
      self.vip_rating = self.vip_rating + 3
    end

    -- check the seating : standing ratio of waiting patients
    local sum_sitting, sum_standing = self.hospital:countSittingStanding()
    if (sum_sitting + sum_standing) ~= 0 then
      if sum_sitting >= sum_standing or sum_standing == 0 then
        self.vip_rating = self.vip_rating - 1
      else
        self.vip_rating = self.vip_rating + 1
      end
    end

    -- check for the average queue length
    if sum_queue == 0 then
      self.vip_rating = self.vip_rating - 1
    else
      local queue_ratio = sum_queue / count_rooms
      local queue_ratio_rangemap = {
        {upper = 0.5, value = -1},
        {upper = 1, value = 0},
        {upper = 1.5, value = 1},
        {value = 2}
      }
      self.vip_rating = self.vip_rating + rangeMapLookup(queue_ratio, queue_ratio_rangemap)
    end
  end

--[[--Group factor 4: Doctor ratios--]]
  -- First get all doctors
  local num_docs = self.hospital:hasStaffOfCategory("Doctor")
  -- not doctors are bad
  if not num_docs then
    self.vip_rating = self.vip_rating + 4
  else
    -- Count num. consultants, num. juniors
    local num_cons = self.hospital:hasStaffOfCategory("Consultant")
    if not num_cons then
      num_cons = 0
    end
    local num_junior = self.hospital:hasStaffOfCategory("Junior")
    if not num_junior then
      num_junior = 0
    end

    -- check consultant and junior proportions
    if num_cons / num_docs > 0.5 then
      self.vip_rating = self.vip_rating - 1
    elseif num_junior / num_docs > 0.5 then
      self.vip_rating = self.vip_rating + 1
    end
  end

--[[--Group factor 5: Rooms--]]
  -- Low room numbers incur a penalty
  if count_rooms < 1 then
    self.vip_rating = self.vip_rating + 4
  else
    if count_rooms < 3 then
      self.vip_rating = self.vip_rating + 1
    end
    -- Room decor average
    local avg_room_eval = self.room_eval / self.num_visited_rooms
    local room_eval_rangemap = {
      {upper = 1.5, value = 3},
      {upper = 2, value = 1},
      {upper = 3, value = 0},
      {value = -1}
    }
    if self.num_visited_rooms ~= 0 then
      self.vip_rating = self.vip_rating + rangeMapLookup(avg_room_eval, room_eval_rangemap)
    end
  end

--[[--Finalise score--]]
  --documented rewards.
  local rewards = {
    [1] = 4000,
    [2] = 2000,
    [3] = 1500,
    [4] = 1200,
    [5] = 800,
    [6] = 400,
    [7] = 200,
    [8] = 0,
  }
--documented reps
  local rep_change = {
    [1] = 50,
    [2] = 45,
    [3] = 40,
    [4] = 35,
    [5] = 30,
    [6] = 25,
    [7] = 20,
    [8] = 15,
    [9] = 10,
    [10] = 5,
    [11] = -5,
    [12] = -10,
    [13] = -15,
    [14] = -20,
    [15] = -25,
  }
  -- set rewards
  self.vip_rating = self.vip_rating > 15 and 15 or self.vip_rating
  self.vip_rating = self.vip_rating < 1 and 1 or self.vip_rating
  self.cash_reward = rewards[self.vip_rating] or 0
  self.rep_reward = rep_change[self.vip_rating]
  self.vip_message = self.vip_rating
  self.hospital.num_vips_ty = self.hospital.num_vips_ty + 1
end

function Vip:afterLoad(old, new)
  if old < 50 then
    self.num_visited_rooms = 0
    self:setNextAction(IdleAction())
    self.waiting = 1
    for _, room in pairs(self.world.rooms) do
      if room.door.reserved_for == self then
        room.door.reserved_for = nil
        room:tryAdvanceQueue()
      end
    end
  end
  if old < 79 then
    self.name = self.hospital.visitingVIP
  end
  if old < 139 then
    self.vip_rating = 8 - math.random(0,5)
    --Make sure we only rate rooms from now on if a VIP was visiting
    self.room_eval = 0
    self.num_visited_rooms = 0
    if #self.world.rooms > 79 then
      self.room_visit_chance = math.floor(#self.world.rooms / 40)
    else
      self.room_visit_chance = 1
    end
    -- if our hospital has more patients than counted visitors adjust enter_patients
    self.enter_patients = #self.hospital.patients + self.enter_visitors - self.hospital.num_visitors
    if self.enter_patients <0 then
      self.enter_patients = 0
    end
    if self.going_home then
      --award max from old code if VIP leaving
      self.vip_rating = 2
      self.cash_reward = 2000
      self.rep_reward = 45
      self.vip_message = 2
    end
    for i, action in ipairs(self.action_queue) do
      if action.name == 'idle' and action.loop_callback and (self.waiting > 1 or i > 1) then
        action:setCount(50):setAfterUse(action.loop_callback)
        action.loop_callback = nil
        self.waiting = nil
        if i == 1 then
          self:queueAction(action, 1)
          self:finishAction()
        end
      end
    end
  end
  Humanoid.afterLoad(self, old, new)
end
