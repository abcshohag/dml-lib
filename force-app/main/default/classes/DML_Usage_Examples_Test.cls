/**
 * PMD False Positives:
 * - ApexUnitTestClassShouldHaveRunAs: examples run as the test user on purpose
 * - ApexUnitTestClassShouldHaveRunRelevantTestsAnnotation: same as DML_Test, these are plain library tests
 **/
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveRunAs,PMD.ApexUnitTestClassShouldHaveRunRelevantTestsAnnotation')
@IsTest
private class DML_Usage_Examples_Test {
    // ============ EXISTING USAGE (must keep working) ============

    @IsTest
    static void existingInsertAndUpdate() {
        new DML().toInsert(new Account(Name = 'My Account')).commitWork();

        Account acc = [SELECT Id FROM Account LIMIT 1];
        new DML().toUpdate(new Account(Id = acc.Id, Name = 'New Name')).commitWork();

        Assert.areEqual('New Name', [SELECT Name FROM Account WHERE Id = :acc.Id].Name, 'Account name should be updated.');
    }

    @IsTest
    static void existingDependencyGraphInAnyOrder() {
        Account acc = new Account(Name = 'Acme');
        Contact con = new Contact(LastName = 'Smith');
        Opportunity opp = new Opportunity(Name = 'Deal', StageName = 'Prospecting', CloseDate = Date.today());

        DML.Result result = new DML()
            .toInsert(DML.Record(con).withRelationship(Contact.AccountId, acc))
            .toInsert(DML.Record(opp).withRelationship(Opportunity.AccountId, acc))
            .toInsert(acc)
            .identifier('Onboarding')
            .commitTransaction();

        Assert.areEqual(acc.Id, [SELECT AccountId FROM Contact WHERE Id = :con.Id].AccountId, 'Contact should be related to the account.');
        Assert.areEqual(acc.Id, [SELECT AccountId FROM Opportunity WHERE Id = :opp.Id].AccountId, 'Opportunity should be related to the account.');
        Assert.areEqual(3, result.inserts().size(), 'Result should contain 3 insert operation results.');
        Assert.areEqual(3, DML.retrieveResultFor('Onboarding').inserts().size(), 'Stored result should contain 3 insert operation results.');
    }

    @IsTest
    static void existingCustomOperationOrder() {
        insert new Account(Name = 'Old');

        new DML(new List<DML.OperationType>{ DML.OperationType.DELETE_DML, DML.OperationType.INSERT_DML })
            .toDelete([SELECT Id FROM Account])
            .toInsert(new Account(Name = 'New'))
            .commitWork();

        Assert.areEqual('New', [SELECT Name FROM Account].Name, 'Only the new account should remain.');
    }

    @IsTest
    static void existingSharedInstance() {
        Account acc = new Account(Name = 'Shared');
        DML.Shared.toInsert(DML.Record(new Contact(LastName = 'A')).withRelationship(Contact.AccountId, acc));
        DML.Shared.toInsert(acc);
        DML.Shared.commitWork();

        Assert.areEqual(1, [SELECT COUNT() FROM Contact WHERE AccountId = :acc.Id], 'Contact should be related to the shared account.');
    }

    @IsTest
    static void existingPartialSuccess() {
        DML.Result result = new DML().toInsert(new List<Contact>{ new Contact(LastName = 'Ok'), new Contact() }).allowPartialSuccess().commitWork();

        Assert.areEqual(1, result.insertsOf(Contact.SObjectType).failures().size(), 'Contact without LastName should fail.');
        Assert.areEqual(1, [SELECT COUNT() FROM Contact], 'Valid contact should be inserted.');
    }

    @IsTest
    static void existingDryRun() {
        Account acc = new Account(Name = 'Acme');
        DML.Result preview = new DML().toInsert(acc).dryRun();

        Assert.isFalse(preview.insertsOf(Account.SObjectType).hasFailures(), 'Dry run should not report failures.');
        Assert.areEqual(0, [SELECT COUNT() FROM Account], 'Dry run should not persist the account.');
    }

    @IsTest
    static void existingMockInTests() {
        DML.mock('AccountService').allInserts();

        new DML().toInsert(new Account(Name = 'Mocked')).identifier('AccountService').commitWork();

        Assert.areEqual(0, [SELECT COUNT() FROM Account], 'Mocked insert should not persist the account.');
        Assert.areEqual(1, DML.retrieveResultFor('AccountService').insertsOf(Account.SObjectType).successes().size(), 'Result should contain the mocked insert.');
    }

    // ============ NEW: STAGES ============

    @IsTest
    static void newNextStageDeleteBeforeInsert() {
        insert new Account(Name = 'Yesterday');

        DML.Result result = new DML().toDelete([SELECT Id FROM Account]).nextStage().toInsert(new Account(Name = 'Today')).commitTransaction();

        Assert.areEqual('Today', [SELECT Name FROM Account].Name, 'Only the account from the second stage should remain.');
        Assert.areEqual(1, result.deletes().size(), 'Result should contain the delete from the first stage.');
        Assert.areEqual(1, result.inserts().size(), 'Result should contain the insert from the second stage.');
    }

    @IsTest
    static void newNextStageUpdateSameRecordTwice() {
        Account acc = new Account(Name = 'Acme');
        insert acc;

        new DML().toUpdate(new Account(Id = acc.Id, Rating = 'Warm')).nextStage().toUpdate(new Account(Id = acc.Id, Rating = 'Hot')).commitWork();

        Assert.areEqual('Hot', [SELECT Rating FROM Account WHERE Id = :acc.Id].Rating, 'Update from the second stage should win.');
    }

    @IsTest
    static void newDoWorkQueriesBetweenStages() {
        Account acc = new Account(Name = 'Acme');
        insert acc;
        List<Opportunity> opps = new List<Opportunity>{
            new Opportunity(Name = 'A', AccountId = acc.Id, StageName = 'Prospecting', CloseDate = Date.today(), Amount = 100),
            new Opportunity(Name = 'B', AccountId = acc.Id, StageName = 'Prospecting', CloseDate = Date.today(), Amount = 250)
        };
        insert opps;

        for (Opportunity opp : opps) {
            opp.StageName = 'Closed Won';
        }

        DML.Result result = new DML().toUpdate(opps).doWork(new RollUpWonRevenue(new Set<Id>{ acc.Id })).commitTransaction();

        Assert.areEqual(350, [SELECT AnnualRevenue FROM Account WHERE Id = :acc.Id].AnnualRevenue, 'Work should roll up won revenue after the first stage.');
        Assert.areEqual(2, result.updates().size(), 'Result should contain opportunity and account updates.');
    }

    @IsTest
    static void newStagesRollBackTogether() {
        Account acc = new Account(Name = 'Keep me');
        insert acc;

        try {
            new DML().toUpdate(new Account(Id = acc.Id, Name = 'Changed')).nextStage().toInsert(new Account()).commitTransaction();
            Assert.fail('Expected the second stage to fail');
        } catch (Exception e) {
            Assert.areEqual('Keep me', [SELECT Name FROM Account WHERE Id = :acc.Id].Name, 'Update from the first stage should be rolled back.');
        }
    }

    @IsTest
    static void newStagesWithMock() {
        DML.mock('Sync').allDmls();

        new DML().toDelete(DML.randomIdGenerator.get(Account.SObjectType)).nextStage().toInsert(new Account(Name = 'Mocked')).identifier('Sync').commitWork();

        DML.Result result = DML.retrieveResultFor('Sync');
        Assert.areEqual(1, result.deletes().size(), 'Result should contain the mocked delete.');
        Assert.areEqual(1, result.inserts().size(), 'Result should contain the mocked insert.');
        Assert.areEqual(0, [SELECT COUNT() FROM Account], 'Mocked DML should not persist anything.');
    }

    public class RollUpWonRevenue implements DML.Work {
        private Set<Id> accountIds;

        public RollUpWonRevenue(Set<Id> accountIds) {
            this.accountIds = accountIds;
        }

        public void execute(DML.Committable nextStage) {
            for (AggregateResult row : [
                SELECT AccountId, SUM(Amount) total
                FROM Opportunity
                WHERE AccountId IN :this.accountIds AND StageName = 'Closed Won'
                GROUP BY AccountId
            ]) {
                nextStage.toUpdate(new Account(Id = (Id) row.get('AccountId'), AnnualRevenue = (Decimal) row.get('total')));
            }
        }
    }
}
