//
//  ParameterEstimation.swift
//  Loop
//
//  Created by Dragan Maksimovic on 7/16/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore

/**
 ParameterEstimation performs analysis of glucose, insulin delivery and meal data over the past 24 hours to compute estimates of multipliers for the user settings: insulin sensitivity (ISF), carb ratio (CR) and default basal rates.
 
 WARNING: parameter estimation is highly-experimental work in progress. Users are strongly advised NOT to make any adjustments to their settings based on the results.
 
 The estimates for the ISF multiplier, the CR multiplier and the Basal multiplier are summarized in a Settings Review report. As an example, an ISF multiplier of 1.1 means that based on the data observed the user's setting for ISF should be increased by 10%.  A star (*) next to a multiplier indicates relatively good quality of data for that  multiplier. A "not available" tag means that the estimate is not reliable based  on the data available.
 
 The multiplier estimates are based on least-square fits to the Loop's ISF/CR/basal model, for data grouped into fasting and carb absorption intervals, with start and end times of the estimation intervals determnined based on the user entries and the outputs of the Loop's dynamic carb absorption algorithm.
 
 For fasting intervals, estimates for ISF and basal rate multipliers are computed based on the data available, while no attempt is made to make an estimate of the CR multiplier. ISF/basal rate multipliers are  also provided for hour-long overlapping fasting subintervals in an  attempt to provide estimates at a finertime resulution. "Unnounced meals?" or "exercise?" warnings may be displayed when the obserbed data depart from the model more significantly.
 
 For carb absorption  intervals, estimates for all three multipliers are computed based on the data available, with the underlying assumption that the user mealentries are approximately correct.
 
 Parameter estimation requires the following inputs from startDate to endDate:
 - glucose: timeline of glucose values
 - insulinEffect: glucose effect of insulin doses
 - basalEffect: glucose effect of suspending basal insulin
 - carbStatuses: carb entry statuses as reported by dynamic carb absorption algorithm
 Parameter estimation generates the following outputs:
 - estimationIntervals: sequence of fasting or carbAbsorbing time intervals, including estimated parameters for each interval
 - parameterEstimationStatus: descriptive state of the class for diagnostic purposes
 */

class ParameterEstimation {
    var startDate: Date
    var endDate: Date
    var glucose: [GlucoseValue] = []
    var insulinEffect: [GlucoseEffect]?
    var basalEffect: [GlucoseEffect]?
    var carbStatuses: [CarbStatus<StoredCarbEntry>] = []
    var estimationIntervals: [EstimationInterval] = []
    var parameterEstimationStatus: String = ""
    
    let unit = HKUnit.milligramsPerDeciliter
    let velocityUnit = HKUnit.milligramsPerDeciliter.unitDivided(by: .minute())
    
    init(startDate: Date, endDate: Date, glucose: [GlucoseValue], insulinEffect: [GlucoseEffect]?, basalEffect: [GlucoseEffect]?, carbStatuses: [CarbStatus<StoredCarbEntry>]) {
        self.startDate = startDate
        self.endDate = endDate
        self.glucose = glucose
        self.insulinEffect = insulinEffect
        self.basalEffect = basalEffect
        self.carbStatuses = carbStatuses
    }
    
    /**
     updateParameterEstimates: assembles estimationIntervals and performs parameter estimation of the intervals from startDate to endDate
     */
    func update() {
        
        // Assemble estimation intervals
        assembleEstimationIntervals()
        
        // Calculate parameter estimates
        for estimationInterval in estimationIntervals {
            
            // Calculate parameter estimates over fasting and carbAbsorption intervals
            let startInterval = estimationInterval.startDate
            let endInterval = estimationInterval.endDate
            estimationInterval.estimatedMultipliers = estimationInterval.estimateParameterMultipliers(startInterval, endInterval)
            
            // Calculate parameter estimates over fasting subIntervals
            if estimationInterval.estimationIntervalType == .fasting {
                var startSubInterval = estimationInterval.startDate
                while startSubInterval.addingTimeInterval(.minutes(60)) <
                    estimationInterval.endDate {
                        var endSubInterval = startSubInterval.addingTimeInterval(.minutes(60))
                        if endSubInterval.addingTimeInterval(.minutes(60)) > estimationInterval.endDate {
                            endSubInterval = estimationInterval.endDate
                        }
                        let estimatedMultipliers = estimationInterval.estimateParameterMultipliers(startSubInterval, endSubInterval)
                        estimationInterval.estimatedMultipliersSubIntervals.append(estimatedMultipliers)
                        startSubInterval = endSubInterval.addingTimeInterval(.minutes(-30))
                }
            }
            
        }
    }
    
    // Assemble fasting and carbAbsorption estimation intervals
    // Overalapping completed meal absorptions are grouped together
    // Active absorptions are excluded
    func assembleEstimationIntervals() {
        var runningEndDate = self.endDate
        for carbStatus in carbStatuses {
            guard
                let entryStart = carbStatus.absorption?.observedDate.start,
                let entryEnd = carbStatus.absorption?.observedDate.end,
                let enteredCarbs = carbStatus.absorption?.total,
                let observedCarbs = carbStatus.absorption?.observed,
                let timeRemaining = carbStatus.absorption?.estimatedTimeRemaining
                else {
                    self.parameterEstimationStatus = "xxx Error: a required carbStatus field is not available."
                    continue
            }
            
            if timeRemaining > 0 {
                // If an active carb absorption entry is detected, clean-up and terminate interval assembly
                if entryStart < self.startDate {
                    self.endDate = self.startDate
                    self.parameterEstimationStatus = "xxx Error: currectly active carb absorption started before estimation start, no data available"
                    return // if active carb absorption started before start of the estimation interval we have no valid intervals available for estimation
                }
                
                if entryStart > self.endDate {
                    // Active absorption starts after the end of the estimation
                    // If need be, insert a trailing fasting interval and return
                    if runningEndDate < self.endDate {
                        //add a fasting interval from runningEndDate to self.endDate
                        let glucoseEffect = self.glucose.filterDateRange(runningEndDate, self.endDate)
                        let insulinEffect = self.insulinEffect?.filterDateRange(runningEndDate, self.endDate)
                        let basalEffect = self.basalEffect?.filterDateRange(runningEndDate, self.endDate)
                        estimationIntervals.append(EstimationInterval(startDate: runningEndDate, endDate: self.endDate, type: .fasting, glucose: glucoseEffect, insulinEffect: insulinEffect, basalEffect: basalEffect))
                    }
                    self.parameterEstimationStatus = "*** Estimation interval assembly completed with a fasting interval. There is an active meal absorption that started after the end of the estimation period."
                    return
                }
                
                if entryStart > runningEndDate {
                    // Add a fasting interval from runningEndDate to self.endDate
                    self.endDate = entryStart
                    let glucoseEffect = self.glucose.filterDateRange(runningEndDate, self.endDate)
                    let insulinEffect = self.insulinEffect?.filterDateRange(runningEndDate, self.endDate)
                    let basalEffect = self.basalEffect?.filterDateRange(runningEndDate, self.endDate)
                    estimationIntervals.append(EstimationInterval(startDate: runningEndDate, endDate: self.endDate, type: .fasting, glucose: glucoseEffect, insulinEffect: insulinEffect, basalEffect: basalEffect))
                    self.parameterEstimationStatus = "*** Estimation interval assembly completed with a fasting interval. There is an active meal  absorption that started before the end of the estimation period."
                    return
                }
                
                runningEndDate = entryStart
                var lastAbsorptionEnd = self.startDate
                for (index, estimationInterval) in self.estimationIntervals.enumerated() {
                    // Remove any completed carb absorption that overlaps with active carb absorption
                    if estimationInterval.estimationIntervalType == .carbAbsorption {
                        if estimationInterval.endDate > runningEndDate {
                            self.estimationIntervals.remove(at: index)
                            runningEndDate = min( runningEndDate, estimationInterval.startDate )
                        } else {
                            lastAbsorptionEnd = max( lastAbsorptionEnd, estimationInterval.endDate )
                        }
                    }
                }
                self.endDate = runningEndDate
                
                if estimationIntervals.count == 0 && self.endDate > self.startDate {
                    // if no intervals assembled so far, add a fasting interval between startDate and endDate
                    let glucoseFasting = self.glucose.filterDateRange(self.startDate, self.endDate)
                    let insulinEffectFasting = self.insulinEffect?.filterDateRange(self.startDate, self.endDate)
                    let basalEffectFasting = self.basalEffect?.filterDateRange(self.startDate, self.endDate)
                    estimationIntervals.append(EstimationInterval(startDate: self.startDate, endDate: self.endDate, type: .fasting, glucose: glucoseFasting, insulinEffect: insulinEffectFasting, basalEffect: basalEffectFasting))
                }
                
                self.parameterEstimationStatus = "*** Assembly of estimation intervals completed by trimming out active meal absorptions."
                return
            }
            
            if entryStart < self.startDate {
                // Carbs started before startDate; move startDate to entryEnd
                self.startDate = max( entryEnd, self.startDate )
                continue
            }
            
            if estimationIntervals.count == 0 {
                // No intervals setup yet and entryStart is greater than self.startDate
                // Add first fasting interval between self.startDate and entryStart
                let glucoseFasting = self.glucose.filterDateRange(self.startDate, entryStart)
                let insulinEffectFasting = self.insulinEffect?.filterDateRange(self.startDate, entryStart)
                let basalEffectFasting = self.basalEffect?.filterDateRange(self.startDate, entryStart)
                estimationIntervals.append(EstimationInterval(startDate: self.startDate, endDate: entryStart, type: .fasting, glucose: glucoseFasting, insulinEffect: insulinEffectFasting, basalEffect: basalEffectFasting))
                
                // Add first carbAbsorption interval entryStart to entryEnd
                let glucoseAbsorbing = self.glucose.filterDateRange(entryStart, entryEnd)
                let insulinEffectAbsorbing = self.insulinEffect?.filterDateRange(entryStart, entryEnd)
                let basalEffectAbsorbing = self.basalEffect?.filterDateRange(entryStart, entryEnd)
                estimationIntervals.append(EstimationInterval(startDate: entryStart, endDate: entryEnd, type: .carbAbsorption, glucose: glucoseAbsorbing, insulinEffect: insulinEffectAbsorbing, basalEffect: basalEffectAbsorbing, enteredCarbs: enteredCarbs, observedCarbs: observedCarbs))
                runningEndDate = entryEnd
            } else {
                // At least one interval has already been setup
                if estimationIntervals.last!.estimationIntervalType == .fasting {
                    estimationIntervals.last!.endDate = entryStart // terminate fasting interval
                    // add carbAbsorption interval from entryStart to entryEnd
                    let glucoseAbsorbing = self.glucose.filterDateRange(entryStart, entryEnd)
                    let insulinEffectAbsorbing = self.insulinEffect?.filterDateRange(entryStart, entryEnd)
                    let basalEffectAbsorbing = self.basalEffect?.filterDateRange(entryStart, entryEnd)
                    estimationIntervals.append(EstimationInterval(startDate: entryStart, endDate: entryEnd, type: .carbAbsorption, glucose: glucoseAbsorbing, insulinEffect: insulinEffectAbsorbing, basalEffect: basalEffectAbsorbing, enteredCarbs: enteredCarbs, observedCarbs: observedCarbs))
                    runningEndDate = entryEnd
                } else {
                    // Here previous estimaton interval must be .carbAbsorption
                    if entryStart > estimationIntervals.last!.endDate {
                        // add fasting interval between last endDate and entryStart
                        let glucoseFasting = self.glucose.filterDateRange(estimationIntervals.last!.endDate, entryStart)
                        let insulinEffectFasting = self.insulinEffect?.filterDateRange(estimationIntervals.last!.endDate, entryStart)
                        let basalEffectFasting = self.basalEffect?.filterDateRange(estimationIntervals.last!.endDate, entryStart)
                        estimationIntervals.append(EstimationInterval(startDate: estimationIntervals.last!.endDate, endDate: entryStart, type: .fasting, glucose: glucoseFasting, insulinEffect: insulinEffectFasting, basalEffect: basalEffectFasting))
                        // Add carbAbsorption interval from entryStart to entryEnd
                        let glucoseAbsorbing = self.glucose.filterDateRange(entryStart, entryEnd)
                        let insulinEffectAbsorbing = self.insulinEffect?.filterDateRange(entryStart, entryEnd)
                        let basalEffectAbsorbing = self.basalEffect?.filterDateRange(entryStart, entryEnd)
                        estimationIntervals.append(EstimationInterval(startDate: entryStart, endDate: entryEnd, type: .carbAbsorption, glucose: glucoseAbsorbing, insulinEffect: insulinEffectAbsorbing, basalEffect: basalEffectAbsorbing, enteredCarbs: enteredCarbs, observedCarbs: observedCarbs))
                        runningEndDate = entryEnd
                    } else {
                        // Merge entry into existing carbAbsorption interval
                        runningEndDate = max(estimationIntervals.last!.endDate, entryEnd)
                        estimationIntervals.last!.endDate = runningEndDate
                        let mergedAbsorptionStartDate = min(estimationIntervals.last!.startDate, entryStart)
                        estimationIntervals.last!.startDate = mergedAbsorptionStartDate
                        let previouslyEnteredCarbGrams = estimationIntervals.last!.enteredCarbs!.doubleValue(for: .gram())
                        let enteredCarbGrams = enteredCarbs.doubleValue(for: .gram())
                        estimationIntervals.last!.enteredCarbs = HKQuantity(unit: .gram(), doubleValue: enteredCarbGrams + previouslyEnteredCarbGrams)
                        let previouslyObservedCarbGrams = estimationIntervals.last!.observedCarbs!.doubleValue(for: .gram())
                        let observedCarbGrams = observedCarbs.doubleValue(for: .gram())
                        estimationIntervals.last!.observedCarbs = HKQuantity(unit: .gram(), doubleValue: observedCarbGrams + previouslyObservedCarbGrams)
                        let glucoseAbsorbing = self.glucose.filterDateRange(mergedAbsorptionStartDate, runningEndDate)
                        let insulinEffectAbsorbing = self.insulinEffect?.filterDateRange(mergedAbsorptionStartDate, runningEndDate)
                        let basalEffectAbsorbing = self.basalEffect?.filterDateRange(mergedAbsorptionStartDate, runningEndDate)
                        estimationIntervals.last!.glucose = glucoseAbsorbing
                        estimationIntervals.last!.insulinEffect = insulinEffectAbsorbing
                        estimationIntervals.last!.basalEffect = basalEffectAbsorbing
                    }
                    
                }
                
            }
        }
        // No more meal entries, the last previously entered interval must be carbAbsorption
        if runningEndDate < self.endDate {
            // Add a fasting interval from runningEndDate to self.endDate
            let glucoseEffect = self.glucose.filterDateRange(runningEndDate, self.endDate)
            let insulinEffect = self.insulinEffect?.filterDateRange(runningEndDate, self.endDate)
            let basalEffect = self.basalEffect?.filterDateRange(runningEndDate, self.endDate)
            estimationIntervals.append(EstimationInterval(startDate: runningEndDate, endDate: self.endDate, type: .fasting, glucose: glucoseEffect, insulinEffect: insulinEffect, basalEffect: basalEffect))
        }
        
        if estimationIntervals.count == 0 && self.endDate > self.startDate {
            // if no intervals assembled so far, add a fasting interval between startDate and endDate
            let glucoseFasting = self.glucose.filterDateRange(self.startDate, self.endDate)
            let insulinEffectFasting = self.insulinEffect?.filterDateRange(self.startDate, self.endDate)
            let basalEffectFasting = self.basalEffect?.filterDateRange(self.startDate, self.endDate)
            estimationIntervals.append(EstimationInterval(startDate: self.startDate, endDate: self.endDate, type: .fasting, glucose: glucoseFasting, insulinEffect: insulinEffectFasting, basalEffect: basalEffectFasting))
        }
        
        self.parameterEstimationStatus = "*** Estimation interval assembly completed with a fasting interval. There is no active meal absorption."
        return
    }
}


/**
 EstimationInterval is a fasting or carbAbsorption time interval over which parameter estimation is performed
 
 Estimation interval includes the following timelines from startDate to endDate:
 - glucose: timeline of glucose values
 - insulinEffect: glucose effect of insulin doses
 - basalEffect: glucose effect of suspending basal insulin
 - enteredCarbs: user-enetered carbs
 - observedCarbs: carbs observed according to dynamic absorption algorithm
 Parameter estimation generates the following for each estimation interval:
 - estimatedMultipliers: estimated ISF, CR and Basal multipliers for the interval
 - estimatedMultipliersSubIntervals:  estimated  ISF and Basal multipliers for hour-long overlapping subintervals within each fasting interval
 - estimationIntervalType: fasting  or carbAbsorption
 */

class EstimationInterval {
    var startDate: Date
    var endDate: Date
    var glucose: [GlucoseValue]?
    var insulinEffect: [GlucoseEffect]?
    var basalEffect: [GlucoseEffect]?
    var enteredCarbs: HKQuantity?
    var observedCarbs: HKQuantity?
    var estimatedMultipliers: EstimatedMultipliers?
    var estimatedMultipliersSubIntervals: [EstimatedMultipliers?] = []
    var estimationIntervalType: EstimationIntervalType
    
    
    let unit = HKUnit.milligramsPerDeciliter
    let velocityUnit = HKUnit.milligramsPerDeciliter.unitDivided(by: .minute())
    
    init(startDate: Date, endDate: Date, type: EstimationIntervalType, glucose: [GlucoseValue], insulinEffect: [GlucoseEffect]?, basalEffect: [GlucoseEffect]? = nil, enteredCarbs: HKQuantity? = nil, observedCarbs: HKQuantity? = nil) {
        self.startDate = startDate
        self.endDate = endDate
        self.estimationIntervalType = type
        self.insulinEffect = insulinEffect
        self.glucose = glucose
        self.basalEffect = basalEffect
        self.enteredCarbs = enteredCarbs
        self.observedCarbs = observedCarbs
    }
    
    // Parameter estimation math, explained in a separate document
    func estimateParameterMultipliers(_ start: Date, _ end: Date) -> EstimatedMultipliers? {
        
        guard
            let glucose = self.glucose?.filterDateRange(start, end),
            let insulinEffect = self.insulinEffect?.filterDateRange(start, end),
            let basalEffect = self.basalEffect?.filterDateRange(start, end),
            glucose.count > 5
            else {
                return( nil )
        }
        
        guard
            let startGlucose = glucose.first?.quantity.doubleValue(for: unit),
            let endGlucose = glucose.last?.quantity.doubleValue(for: unit),
            let startInsulin = insulinEffect.first?.quantity.doubleValue(for: unit),
            let endInsulin = insulinEffect.last?.quantity.doubleValue(for: unit),
            let startBasal = basalEffect.first?.quantity.doubleValue(for: unit),
            let endBasal = basalEffect.last?.quantity.doubleValue(for: unit)
            else {
                return( nil )
        }
        
        let deltaGlucose = endGlucose - startGlucose
        let deltaGlucoseInsulin = startInsulin - endInsulin
        let deltaGlucoseBasal = endBasal - startBasal
        
        var actualOverObservedRatio = 0.0
        if let observedCarbs = self.observedCarbs?.doubleValue(for: .gram()),
            let enteredCarbs = self.enteredCarbs?.doubleValue(for: .gram()),
            enteredCarbs > 0 {
            let observedOverEnteredRatio = observedCarbs / enteredCarbs
            actualOverObservedRatio = (1.0 / observedOverEnteredRatio).squareRoot()
        }
        
        let insulinWeight = -deltaGlucose
        let carbWeight = actualOverObservedRatio * (deltaGlucose + deltaGlucoseInsulin)
        let basalWeight = deltaGlucoseBasal
        let insulinBasalWeight = deltaGlucoseInsulin + deltaGlucoseBasal
        
        let (insulinSensitivityMultiplierInverse, carbRatioMultiplierInverse, basalMultiplier) = projectionToPlane(a: insulinWeight, b: carbWeight, c: basalWeight, d: insulinBasalWeight)
        let insulinSensitivityMultiplier = 1.0 / insulinSensitivityMultiplierInverse
        let carbRatioMultiplier = 1.0 / carbRatioMultiplierInverse
        
        let estimatedMultipliers = EstimatedMultipliers(startDate: start, endDate: end, basalMultiplier: basalMultiplier, insulinSensitivityMultiplier: insulinSensitivityMultiplier, carbSensitivityMultiplier: insulinSensitivityMultiplier, carbRatioMultiplier: carbRatioMultiplier, deltaGlucose: deltaGlucose, deltaGlucoseInsulin: deltaGlucoseInsulin, deltaGlucoseBasal: deltaGlucoseBasal)
        
        return( estimatedMultipliers )
    }
    
}

/**
 EstimatedMultipliers collect the key data variables and the parameter  estimation outputs: the estimated multipliers for ISF, CR  and Basal  rate
 
 EstimatedMultipliers variables for an interval from startDate to endDate
 - basalMultiplier: estimated/user-setting for Basal rate (effect during estimation interval)
 - insulinSensitivityMultiplier: estimated/user-setting for ISF
 - carbRatioMultiplier: estimated/user-setting for CR
 - deltaGlucose = glucose(endDate) - glucose(startDate)
 - deltaGlucoseInsulin = insulinEffect(startDate) - insulinEffect(endDate)
 - deltaGlucoseBasal = zeroBasalEffect(endDate) - zeroBasalEffect(startDate)
 */

class EstimatedMultipliers {
    var startDate: Date
    var endDate: Date
    var basalMultiplier: Double
    var insulinSensitivityMultiplier: Double
    var carbSensitivityMultiplier: Double
    var carbRatioMultiplier: Double
    var deltaGlucose: Double
    var deltaGlucoseInsulin: Double
    var deltaGlucoseBasal: Double
    
    init(startDate: Date, endDate: Date, basalMultiplier: Double, insulinSensitivityMultiplier: Double, carbSensitivityMultiplier: Double, carbRatioMultiplier: Double, deltaGlucose: Double, deltaGlucoseInsulin: Double, deltaGlucoseBasal: Double) {
        self.startDate = startDate
        self.endDate = endDate
        self.basalMultiplier = basalMultiplier
        self.insulinSensitivityMultiplier = insulinSensitivityMultiplier
        self.carbSensitivityMultiplier = carbSensitivityMultiplier
        self.carbRatioMultiplier = carbRatioMultiplier
        self.deltaGlucose = deltaGlucose
        self.deltaGlucoseInsulin = deltaGlucoseInsulin
        self.deltaGlucoseBasal = deltaGlucoseBasal
    }
    
    
    /**
     Generate narrative interpretation of the parameter estimation results
     Returns text for the Settings Review report
     */
    func reviewReport(_ estimationIntervalType: EstimationIntervalType) -> [String] {
        
        let dateFormatter = DateFormatter()
        dateFormatter.timeStyle = .short
        dateFormatter.dateStyle = .short
        
        var reviewReport: [String] = []
        
        let reportInsulinSensitivityMultiplier = (insulinSensitivityMultiplier * 100).rounded() / 100
        let reportCarbRatioMultiplier = (carbRatioMultiplier * 100).rounded() / 100
        let reportBasalMultiplier = (basalMultiplier * 100).rounded() / 100
        
        var isfTag = "?"
        var basalTag = "?"
        var crTag = "?"
        switch estimationIntervalType {
        case .fasting:
            if deltaGlucose * deltaGlucoseInsulin < 0 && abs(deltaGlucose) > 0.5 * deltaGlucoseBasal {
                isfTag = "!"
            }
            if deltaGlucoseBasal > 0.5 * abs(deltaGlucose) {
                basalTag = "!"
            }
            reviewReport += ["\(dateFormatter.string(from: startDate)) to \(dateFormatter.string(from: endDate))"]
            if (insulinSensitivityMultiplier > 1.1 && basalMultiplier > 1.1) || (insulinSensitivityMultiplier < 0.9 && basalMultiplier < 0.9){
                reviewReport += ["ISF multiplier: not available"]
            } else {
                reviewReport += ["ISF multiplier: \(reportInsulinSensitivityMultiplier) \(isfTag)"]
            }
            if (insulinSensitivityMultiplier > 1.1 && basalMultiplier > 1.5) || (insulinSensitivityMultiplier < 0.9 && basalMultiplier < 0.5){
                reviewReport += ["Basal multiplier: not available"]
            } else {
                reviewReport += ["Basal multiplier: \(reportBasalMultiplier) \(basalTag)"]
            }
            if (insulinSensitivityMultiplier > 1.25 && basalMultiplier > 1.25) || basalMultiplier >  1.5 {
                reviewReport += ["Warning: unannounced meals or site issues?"]
            }
            if (insulinSensitivityMultiplier > 1.25 && basalMultiplier < 0.75) || basalMultiplier <  0.5 {
                reviewReport += ["Warning: exercise?"]
            }
            
        case .carbAbsorption:
            reviewReport += ["\(dateFormatter.string(from: startDate)) to \(dateFormatter.string(from: endDate))"]
            if abs( carbRatioMultiplier - 1.0 ) < 0.02 {
                reviewReport += ["Good observed/entered carbs match,"]
                reviewReport += ["parameter estimates are not available"]
            } else {
                if abs(deltaGlucose) > 0.5 * deltaGlucoseBasal && abs(deltaGlucose) > 0.5 * (deltaGlucose + deltaGlucoseInsulin) {
                    isfTag = "!"
                }
                if deltaGlucoseBasal > 0.5 * abs(deltaGlucose) && deltaGlucoseBasal > 0.5 * (deltaGlucose + deltaGlucoseInsulin) {
                    basalTag = "!"
                }
                if (deltaGlucose + deltaGlucoseInsulin) > 0.5 * abs(deltaGlucose) && (deltaGlucose + deltaGlucoseInsulin) > deltaGlucoseBasal {
                    crTag = "!"
                }
                reviewReport += ["ISF multiplier: \(reportInsulinSensitivityMultiplier) \(isfTag)"]
                reviewReport += ["Basal multiplier: \(reportBasalMultiplier) \(basalTag)"]
                reviewReport += ["CR multiplier: \(reportCarbRatioMultiplier) \(crTag)"]
            }
            
        default: reviewReport = ["Error: unknown estimation interval type"]
        }
        
        return( reviewReport )
        
    }
    
}

struct EstimationIntervalType: OptionSet {
    let rawValue: Int
    
    static let carbAbsorption = EstimationIntervalType(rawValue: 1 << 0)
    static let fasting = EstimationIntervalType(rawValue: 1 << 1)
}

/// Least-square parameter estimation math: notes included in a separate document
/// Projection of point (1, 1, 1) to plane a * x + b * y + c * z = d
fileprivate func projectionToPlane(a: Double, b: Double, c: Double, d: Double) -> (Double, Double, Double) {
    let dotProduct = pow(a, 2.0) + pow(b, 2.0) + pow(c, 2.0)
    if dotProduct == 0.0 {
        return(1.0, 1.0, 1.0)
    } else {
        let p1 = (pow(b, 2.0) + pow(c, 2.0) - a * (b + c - d) ) / dotProduct
        let p2 = (pow(a, 2.0) + pow(c, 2.0) - b * (a + c - d) ) / dotProduct
        let p3 = (pow(a, 2.0) + pow(b, 2.0) - c * (a + b - d) ) / dotProduct
        return(p1, p2, p3)
    }
}

/// filterDataRange for [GlucoseValue]
extension Collection where Iterator.Element == GlucoseValue {
    func filterDateRange(_ startDate: Date?, _ endDate: Date?) -> [Iterator.Element] {
        return filter { (value) -> Bool in
            if let startDate = startDate, value.endDate < startDate {
                return false
            }
            
            if let endDate = endDate, value.startDate > endDate {
                return false
            }
            
            return true
        }
    }
}

/// Generate Settings Review report (also included in the Loop Issue Report)
extension ParameterEstimation {
    /// Generates a diagnostic report about the current state
    ///
    /// - parameter completion: A closure called once the report has been generated. The closure takes a single argument of the report string.
    func generateReport(_ completion: @escaping (_ report: String) -> Void) {
        
        let dateFormatter = DateFormatter()
        dateFormatter.timeStyle = .short
        dateFormatter.dateStyle = .short
        
        var report: [String] = []
        
        report += ["=================================="]
        report += ["Settings Review Period\n\(dateFormatter.string(from: self.startDate)) to \(dateFormatter.string(from: self.endDate))"]
        report += ["=================================="]
        
        for estimationInterval in estimationIntervals {
            
            guard let estimationIntervalReport = estimationInterval.estimatedMultipliers?.reviewReport(estimationInterval.estimationIntervalType)
                else { continue }
            
            switch  estimationInterval.estimationIntervalType {
            case .fasting: report += ["** Fasting **"]
            case .carbAbsorption: report += ["** Meal absorption **"]
            default: report += ["** Error: unknown estimation interval type **\n"]
            }
            
            report += estimationIntervalReport
            report += ["----------------------------------"]
        }
        
        report += ["\n=================================="]
        report += ["Fasting subintervals"]
        report += ["=================================="]
        
        for estimationInterval in estimationIntervals {
            if estimationInterval.estimationIntervalType == .fasting {
                report += ["----------------------------------"]
                report += ["\(dateFormatter.string(from: estimationInterval.startDate)) to \(dateFormatter.string(from: estimationInterval.endDate))"]
                report += ["----------------------------------"]
                for estimationSubInterval in estimationInterval.estimatedMultipliersSubIntervals {
                    
                    guard let estimationSubIntervalReport = estimationSubInterval?.reviewReport(estimationInterval.estimationIntervalType)
                        else { continue }
                    report += estimationSubIntervalReport
                    report += ["---"]
                }
            }
        }
        report += ["\n=================================="]
        report += ["Parameter estimation diagnostics"]
        report += ["=================================="]
        report += ["## Estimation period"]
        report += ["\(dateFormatter.string(from: self.startDate)) to: \(dateFormatter.string(from: self.endDate))"]
        report += [self.parameterEstimationStatus]
        for estimationInterval in estimationIntervals {
            switch  estimationInterval.estimationIntervalType {
            case .fasting: report += ["\n** Fasting **"]
            case .carbAbsorption: report += ["\n** Meal absorption **"]
            default: report += ["\n** Error: unknown estimation interval type **\n"]
            }
            report += ["\(dateFormatter.string(from: estimationInterval.startDate)) to \(dateFormatter.string(from: estimationInterval.endDate))"]
            report += ["-----"]
            guard
                let deltaGlucose = estimationInterval.estimatedMultipliers?.deltaGlucose,
                let deltaGlucoseInsulin = estimationInterval.estimatedMultipliers?.deltaGlucoseInsulin,
                let deltaGlucoseBasal = estimationInterval.estimatedMultipliers?.deltaGlucoseBasal,
                let isfMultiplier = estimationInterval.estimatedMultipliers?.insulinSensitivityMultiplier,
                let crMultiplier = estimationInterval.estimatedMultipliers?.carbRatioMultiplier,
                let basalMultiplier = estimationInterval.estimatedMultipliers?.basalMultiplier
                else { continue
            }
            report += ["deltaGlucose: \(deltaGlucose)"]
            report += ["deltaGlucoseInsulin: \(deltaGlucoseInsulin)"]
            report += ["deltaGlucoseBasal: \(deltaGlucoseBasal)"]
            report += ["ISF multiplier: \(isfMultiplier)"]
            report += ["Basal multiplier: \(basalMultiplier)"]
            report += ["CR multiplier: \(crMultiplier)"]
            report += ["Entered: \(String(describing: estimationInterval.enteredCarbs?.doubleValue(for: .gram())))"]
            report += ["Observed: \(String(describing: estimationInterval.observedCarbs?.doubleValue(for: .gram())))"]
            report += ["----"]
        }
        
        report += ["\n=================================="]
        report += ["Fasting subintervals diagnostics"]
        report += ["=================================="]
        for estimationInterval in estimationIntervals {
            if estimationInterval.estimationIntervalType == .fasting {
                report += ["----------------------------------"]
                report += ["\(dateFormatter.string(from: estimationInterval.startDate)) to \(dateFormatter.string(from: estimationInterval.endDate))"]
                report += ["----------------------------------"]
                for estimationSubInterval in estimationInterval.estimatedMultipliersSubIntervals {
                    guard let start = estimationSubInterval?.startDate,
                        let end = estimationSubInterval?.endDate,
                        let deltaGlucose = estimationSubInterval?.deltaGlucose,
                        let deltaGlucoseInsulin = estimationSubInterval?.deltaGlucoseInsulin,
                        let deltaGlucoseBasal = estimationSubInterval?.deltaGlucoseBasal,
                        let isfMultiplier = estimationSubInterval?.insulinSensitivityMultiplier,
                        let basalMultiplier = estimationSubInterval?.basalMultiplier
                        else { continue
                    }
                    report += ["\(dateFormatter.string(from: start)) to \(dateFormatter.string(from: end))"]
                    report += ["deltaGlucose: \(deltaGlucose)"]
                    report += ["deltaGlucoseInsulin: \(deltaGlucoseInsulin)"]
                    report += ["deltaGlucoseBasal: \(deltaGlucoseBasal)"]
                    report += ["ISF multiplier: \(isfMultiplier)"]
                    report += ["Basal multiplier: \(basalMultiplier)"]
                    report += ["---"]
                }
            }
        }
        
        
        report += ["\n -----------------------------------"]
        report += ["Paramater estimation timelines"]
        report += ["-----------------------------------"]
        
        // Glucose values
        report += ["*** Glucose values (start, mg/dL) \n",
                   self.glucose.reduce(into: "", { (entries, entry) in
                    entries.append("* \(dateFormatter.string(from: entry.startDate)), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                   })]
        
        // Insulin effects
        report += ["\n *** Insulin effects (start, mg/dL) \n",
                   (self.insulinEffect ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(dateFormatter.string(from: entry.startDate)), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                   })]
        
        // Zero basal effects
        report += ["\n *** Zero basal effects (start, mg/dL) \n",
                   (self.basalEffect ?? []).reduce(into: "", { (entries, entry) in
                    entries.append("* \(dateFormatter.string(from: entry.startDate)), \(entry.quantity.doubleValue(for: .milligramsPerDeciliter))\n")
                   })]
        
        // Carb entry statuses
        report += ["\n *** carbStatuses: \(self.carbStatuses) \n"]
        
        report.append("")
        completion(report.joined(separator: "\n"))
    }
    
}
